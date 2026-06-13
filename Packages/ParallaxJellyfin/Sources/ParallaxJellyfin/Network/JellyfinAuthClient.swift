import Foundation
import JellyfinAPI

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

public final class DefaultJellyfinAuthClient: JellyfinAuthClient, Sendable {
    public let serverURL: URL
    private let identity: DeviceIdentity

    public init(serverURL: URL, identity: DeviceIdentity) {
        self.serverURL = serverURL
        self.identity = identity
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
        return JellyfinClient(configuration: config)
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

    public func quickConnectEvents() -> AsyncThrowingStream<QuickConnect.Event, Error> {
        newClient().quickConnect.connect()
    }
}
