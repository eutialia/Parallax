import Foundation
import Testing
import ParallaxCore
import ParallaxJellyfin
@testable import Parallax

/// The Connect gate must not require a password. Jellyfin accounts can be passwordless
/// (`HasPassword: false`) and `AuthenticateByName` issues a token for an empty `Pw` — the official
/// demo server's `demo` user is exactly that, and it's the account an App Store reviewer signs in
/// with. The gate used to require a filled password, which locked every such account out of the app
/// with a permanently disabled button and no error to explain it.
/// One state of the three Connect fields and whether the button is live.
struct ConnectGateCase: Sendable, CustomTestStringConvertible {
    let name: String
    let server: String
    let username: String
    let password: String
    let canSubmit: Bool
    var testDescription: String { name }
}

private let demoServer = "demo.jellyfin.org/stable"

private let connectGateCases: [ConnectGateCase] = [
    // THE case this suite exists for: the official demo account has no password, and it's the
    // account an App Store reviewer signs in with.
    ConnectGateCase(name: "passwordless account", server: demoServer, username: "demo", password: "", canSubmit: true),
    ConnectGateCase(name: "everything filled", server: demoServer, username: "demo", password: "hunter2", canSubmit: true),
    // Whitespace-only, not merely empty: the field is trimmed before the gate reads it.
    ConnectGateCase(name: "whitespace username", server: demoServer, username: "   ", password: "hunter2", canSubmit: false),
    ConnectGateCase(name: "empty username", server: demoServer, username: "", password: "hunter2", canSubmit: false),
    ConnectGateCase(name: "no server", server: "", username: "demo", password: "hunter2", canSubmit: false),
    ConnectGateCase(name: "whitespace server", server: "  ", username: "demo", password: "hunter2", canSubmit: false),
    ConnectGateCase(name: "nothing at all", server: "", username: "", password: "", canSubmit: false),
]

@Suite("Login view model · Connect gate")
@MainActor
struct LoginViewModelTests {
    /// The gate never reaches the network, so the `SessionManager` is pure scaffolding —
    /// `UnusedJellyfinClientFactory` traps if a test ever does walk into it.
    private func makeViewModel() -> LoginViewModel {
        let store = makeIsolatedServerStore(label: "LoginViewModelTests")
        return LoginViewModel(
            sessionManager: SessionManager(serverStore: store, factory: UnusedJellyfinClientFactory())
        )
    }

    @Test("the Connect gate requires a server and a username — and nothing else", arguments: connectGateCases)
    func canSubmitPassword(_ gate: ConnectGateCase) {
        let vm = makeViewModel()
        vm.serverURLInput = gate.server
        vm.username = gate.username
        vm.password = gate.password
        #expect(vm.canSubmitPassword == gate.canSubmit)
    }

    /// Reverse-proxied servers live under a path prefix, and the demo server is one
    /// (`/stable`). `normalize` must keep the path — dropping it would send every request to the
    /// host root and 404.
    @Test("normalize keeps a reverse-proxy path prefix and adds https")
    func normalizeKeepsPathPrefix() throws {
        let url = try #require(LoginViewModel.normalize(" demo.jellyfin.org/stable "))
        #expect(url.absoluteString == "https://demo.jellyfin.org/stable")
    }
}
