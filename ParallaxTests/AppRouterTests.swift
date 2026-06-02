import Testing
import Foundation
import ParallaxJellyfin
@testable import Parallax

@MainActor
struct AppRouterTests {
    private func session(_ rawID: String) -> Session {
        Session(
            persisted: PersistedSession(
                id: ServerID(rawValue: rawID),
                serverURL: URL(string: "https://\(rawID).example.test")!,
                serverName: "Server \(rawID)",
                user: UserSnapshot(id: "user-\(rawID)", name: "User", serverLastUpdatedAt: nil)
            ),
            accessToken: "token-\(rawID)"
        )
    }

    @Test("updateForCurrentSession routes to home and tracks the active server id")
    func tracksActiveServer() {
        let router = AppRouter()
        router.updateForCurrentSession(session("alpha"))
        #expect(router.destination == .home)
        #expect(router.activeServerID == ServerID(rawValue: "alpha"))
    }

    // The regression this guards: a switch must CHANGE activeServerID, because
    // RootTabView keys its tab remount on it. The original bug was that nothing
    // updated this on a Servers-tab switch, so the tabs stayed on the old server.
    @Test("a server switch changes activeServerID")
    func switchChangesActiveID() {
        let router = AppRouter()
        router.updateForCurrentSession(session("alpha"))
        router.updateForCurrentSession(session("beta"))
        #expect(router.activeServerID == ServerID(rawValue: "beta"))
    }

    @Test("a nil session (last sign-out) routes to login and clears activeServerID")
    func nilSessionClears() {
        let router = AppRouter()
        router.updateForCurrentSession(session("alpha"))
        router.updateForCurrentSession(nil)
        #expect(router.destination == .login)
        #expect(router.activeServerID == nil)
    }

    @Test("goToLogin clears activeServerID")
    func goToLoginClears() {
        let router = AppRouter()
        router.updateForCurrentSession(session("alpha"))
        router.goToLogin()
        #expect(router.activeServerID == nil)
    }
}
