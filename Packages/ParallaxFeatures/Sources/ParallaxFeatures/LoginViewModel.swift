import Foundation
import Observation
import os
import ParallaxCore
import ParallaxJellyfin

@Observable
@MainActor
public final class LoginViewModel {
    public enum Mode { case password, quickConnect }

    public var serverURLInput: String
    public var username: String = ""
    public var password: String = ""
    public private(set) var isWorking: Bool = false
    public private(set) var errorMessage: String?
    public private(set) var mode: Mode = .password

    private let app: AppModel
    private let discovery: LANServerDiscovery
    /// Settings' add-server flow passes a closure to refresh + pop. Nil on the logged-out Connect
    /// path, where the model drives the router itself.
    private let onSignedIn: (() -> Void)?

    /// - Parameter prefilledServerURL: Seeds the server field when re-authenticating a server
    ///   Parallax already knows. Set, it also suppresses LAN autofill: a discovered server is a
    ///   guess, and it must not overwrite the exact address the user asked to sign back into.
    public init(app: AppModel, prefilledServerURL: String? = nil, onSignedIn: (() -> Void)? = nil) {
        self.app = app
        discovery = app.services.lanDiscovery
        serverURLInput = prefilledServerURL ?? ""
        self.onSignedIn = onSignedIn
    }

    /// Server + username are required; the password is not. Jellyfin accounts can have no
    /// password at all (`HasPassword: false` — the official demo server's `demo` user is one),
    /// and `AuthenticateByName` accepts an empty `Pw` for them. Gating on a filled password
    /// would lock those accounts out of the app entirely. Matches `SMBLoginView.canConnect`,
    /// where a blank account means guest.
    public var canSubmitPassword: Bool {
        hasServerURL && !trimmedUsername.isEmpty
    }

    /// Quick Connect only needs to know which server to pair with.
    public var canUseQuickConnect: Bool { hasServerURL }

    private var hasServerURL: Bool {
        !serverURLInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Jellyfin usernames carry no leading/trailing whitespace, but AutoFill and paste
    /// routinely add some — trim once here so the gate and the request agree.
    private var trimmedUsername: String {
        username.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - LAN discovery

    public var discoveredServers: [DiscoveredServer] { discovery.discovered }

    /// Discovery runs only while the sign-in screen is up: the call triggers the iOS Local Network
    /// permission prompt here (not mid-library browse), and ending the calling task stops it.
    /// Retries catch a late grant during the permission alert. Fills the server field from the
    /// first server found, whenever it lands — discovery races the permission prompt.
    public func discoverServers() async {
        let activations = app.lifecycle.activations
        discovery.start(retries: 3, retryInterval: .seconds(2))
        defer { discovery.stop() }
        await withDiscardingTaskGroup { group in
            group.addTask { await self.prefillFromDiscovery() }
            group.addTask { await self.rescan(after: activations) }
        }
    }

    private func prefillFromDiscovery() async {
        for await address in Observations({ self.discovery.discovered.first?.address }) {
            if let address, serverURLInput.isEmpty { serverURLInput = address.absoluteString }
        }
    }

    /// iOS exposes no Local Network authorization API, so every activation rescans: the user may
    /// have just tapped Allow on the prompt, or come back from Settings with access granted.
    private func rescan(after activations: Int) async {
        var seen = activations
        for await count in Observations({ self.app.lifecycle.activations }) where count != seen {
            seen = count
            discovery.start()
        }
    }

    // MARK: - Sign in

    /// Signs in with the typed credentials, then runs the success path.
    public func submit() async {
        if await signIn() { await completeSignIn() }
    }

    /// The success path both sign-in modes share: the add-server caller refreshes and pops, or on the
    /// logged-out root the router moves off login. Routing through `routeToSources` sets destination
    /// AND activeServerID together; the per-source tasks (Home/Library/Search/RootTabView) are gated
    /// on the router's source state, so setting only `destination` would strand every tab on its
    /// loading skeleton.
    public func completeSignIn() async {
        if let onSignedIn {
            onSignedIn()
        } else {
            await app.routeToSources()
        }
    }

    private func signIn() async -> Bool {
        errorMessage = nil
        guard let url = Self.normalize(serverURLInput) else {
            errorMessage = "That server URL doesn't look right. Check it and try again."
            return false
        }
        let account = trimmedUsername
        guard !account.isEmpty else {
            errorMessage = "Enter your username."
            return false
        }
        isWorking = true
        defer { isWorking = false }

        do {
            _ = try await app.services.sessionManager.signIn(server: url, username: account, password: password)
            return true
        } catch let error as AppError {
            Log.auth.error("LoginView signIn failed: \(error.userMessage)")
            errorMessage = error.userMessage
            return false
        } catch {
            Log.auth.error("LoginView signIn unexpected: \(String(describing: type(of: error)))")
            errorMessage = "Couldn't sign in. Try again."
            return false
        }
    }

    public func switchToQuickConnect() {
        mode = .quickConnect
    }

    public func switchToPassword() {
        mode = .password
    }

    public func makeQuickConnectModel() -> QuickConnectViewModel {
        QuickConnectViewModel(
            sessionManager: app.services.sessionManager,
            onSignedIn: { [weak self] in await self?.completeSignIn() }
        )
    }

    public static func normalize(_ input: String) -> URL? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let withScheme: String
        if trimmed.lowercased().hasPrefix("http://") || trimmed.lowercased().hasPrefix("https://") {
            withScheme = trimmed
        } else {
            withScheme = "https://\(trimmed)"
        }
        guard let url = URL(string: withScheme), url.host != nil else { return nil }
        return url
    }
}
