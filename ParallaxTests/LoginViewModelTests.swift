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

    @Test("A passwordless account can submit — server + username is enough")
    func blankPasswordSubmits() {
        let vm = makeViewModel()
        vm.serverURLInput = "demo.jellyfin.org/stable"
        vm.username = "demo"
        vm.password = ""
        #expect(vm.canSubmitPassword)
    }

    @Test("A whitespace-only username does not submit")
    func blankUsernameBlocked() {
        let vm = makeViewModel()
        vm.serverURLInput = "demo.jellyfin.org/stable"
        vm.username = "   "
        vm.password = "hunter2"
        #expect(!vm.canSubmitPassword)
    }

    @Test("A missing server does not submit")
    func blankServerBlocked() {
        let vm = makeViewModel()
        vm.username = "demo"
        vm.password = "hunter2"
        #expect(!vm.canSubmitPassword)
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
