import Foundation
import JellyfinAPI
import ParallaxCore

/// A narrow protocol over what `SessionManager` and `ServerStore` need from a Jellyfin
/// server connection. Implementations:
///   - `DefaultJellyfinAuthClient` (production, wraps a real `JellyfinClient`)
///   - `FakeJellyfinAuthClient` (tests, programmable canned responses)
public protocol JellyfinAuthClient: Sendable {
    /// The server this client authenticates against.
    var serverURL: URL { get }

    /// Authenticate with username + password.
    func signIn(username: String, password: String) async throws -> AuthenticationResult
    /// Authenticate with a Quick Connect secret surfaced by `quickConnectEvents()`.
    func signIn(quickConnectSecret: String) async throws -> AuthenticationResult
    /// Revoke the access token server-side (best-effort; a 401/offline state is tolerated).
    func signOut(accessToken: String) async throws
    /// Fetch unauthenticated server info (name, id, version) for display and serverID resolution.
    func fetchPublicSystemInfo() async throws -> PublicSystemInfo
    /// Stream Quick Connect lifecycle events — the code to show the user, then the approved secret.
    func quickConnectEvents() -> AsyncThrowingStream<QuickConnect.Event, Error>
}

public extension JellyfinAuthClient {
    /// The server's version string from the public-info endpoint, decoupled from the SDK's
    /// `PublicSystemInfo` so app-target callers (e.g. the server-detail screen) don't import `JellyfinAPI`.
    /// A thrown call doubles as the offline signal — there's no live status stream, so a successful fetch
    /// IS the point-in-time "reachable" proof.
    func serverVersion() async throws -> String? {
        try await fetchPublicSystemInfo().version
    }
}

/// How long a Quick Connect code stays alive: the device asks the server for its approval state
/// every `interval` until `maxPolls` attempts are spent.
///
/// The budget lives here — not in the SDK's `QuickConnect` helper — because *whose deadline it is*
/// decides what "expired" can be typed as. The helper signals exhaustion with
/// `QuickConnect.QuickConnectError.maxPollingHit`, an **internal** case of an **internal** enum
/// (`jellyfin-sdk-swift/Sources/QuickConnect.swift`), so a caller can only recognise it by
/// stringifying the error — one upstream rename away from silently reading an expiry as a crash.
/// Owning the loop makes expiry ours to throw as a typed `AppError.auth(.quickConnectExpired)`.
public struct QuickConnectPolling: Sendable {
    /// Matches the SDK helper's own defaults (5 s × 200 ≈ 16 minutes), so replacing it changed
    /// no timing.
    public static let `default` = QuickConnectPolling(interval: .seconds(5), maxPolls: 200)

    public var interval: Duration
    public var maxPolls: Int

    public init(interval: Duration, maxPolls: Int) {
        self.interval = interval
        self.maxPolls = maxPolls
    }
}

public final class DefaultJellyfinAuthClient: JellyfinAuthClient, Sendable {
    public let serverURL: URL
    private let identity: DeviceIdentity
    /// See `DefaultJellyfinLibraryClient.sessionConfiguration` — the injected transport that lets
    /// tests drive the real request path against a stub `URLProtocol`.
    private let sessionConfiguration: URLSessionConfiguration
    private let quickConnectPolling: QuickConnectPolling

    public init(
        serverURL: URL,
        identity: DeviceIdentity,
        sessionConfiguration: URLSessionConfiguration = .default,
        quickConnectPolling: QuickConnectPolling = .default
    ) {
        self.serverURL = serverURL
        self.identity = identity
        self.sessionConfiguration = sessionConfiguration
        self.quickConnectPolling = quickConnectPolling
    }

    private func newClient(accessToken: String? = nil) -> JellyfinClient {
        let config = JellyfinClient.Configuration(
            url: serverURL,
            accessToken: accessToken,
            client: identity.client,
            deviceName: identity.deviceName,
            deviceID: identity.deviceID,
            version: identity.version
        )
        return JellyfinClient(configuration: config, sessionConfiguration: sessionConfiguration)
    }

    public func signIn(username: String, password: String) async throws -> AuthenticationResult {
        try await newClient().signIn(username: username, password: password)
    }

    public func signIn(quickConnectSecret: String) async throws -> AuthenticationResult {
        try await newClient().signIn(quickConnectSecret: quickConnectSecret)
    }

    public func signOut(accessToken: String) async throws {
        // Build a one-shot client carrying the token solely so the SDK can
        // POST the revoke. The token never enters Keychain via this path.
        try await newClient(accessToken: accessToken).signOut()
    }

    public func fetchPublicSystemInfo() async throws -> PublicSystemInfo {
        let request = Paths.getPublicSystemInfo
        let response = try await newClient().send(request)
        return response.value
    }

    /// Runs the Quick Connect handshake over the SDK's own endpoints (`Paths.initiateQuickConnect`
    /// / `Paths.getQuickConnectState`), which is exactly what `JellyfinClient.quickConnect.connect()`
    /// does — with the failures typed, since we own the loop. See `QuickConnectPolling`.
    public func quickConnectEvents() -> AsyncThrowingStream<QuickConnect.Event, Error> {
        let client = newClient()
        let polling = quickConnectPolling
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await Self.runQuickConnect(client: client, polling: polling) { event in
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch is CancellationError {
                    // A cancelled run isn't a failure — finish cleanly and let the caller read
                    // `Task.isCancelled` to tell "torn down" from "the server gave up".
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func runQuickConnect(
        client: JellyfinClient,
        polling: QuickConnectPolling,
        yield: (QuickConnect.Event) -> Void
    ) async throws {
        let initiated = try await client.send(Paths.initiateQuickConnect).value
        guard let secret = initiated.secret, let code = initiated.code else {
            // The server accepted the request but named no code, so there is nothing to show and
            // nothing to poll. Not an auth verdict — the pairing never got off the ground.
            throw AppError.unexpected("Jellyfin Quick Connect: server returned no pairing code", underlying: nil)
        }

        yield(.polling(code: code))

        for _ in 0 ..< polling.maxPolls {
            let state = try await client.send(Paths.getQuickConnectState(secret: secret)).value
            if state.isAuthenticated == true, let approvedSecret = state.secret {
                yield(.authenticated(secret: approvedSecret))
                return
            }
            try await Task.sleep(for: polling.interval)
        }

        // The budget is spent with nobody approving the code: that IS expiry, typed at the layer
        // that set the deadline.
        throw AppError.auth(.quickConnectExpired)
    }
}
