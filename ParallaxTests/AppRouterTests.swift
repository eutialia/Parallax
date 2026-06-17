import Testing
import Foundation
import ParallaxJellyfin
@testable import Parallax

@MainActor
struct AppRouterTests {
    private func session(_ rawID: String) -> Session {
        Session(
            id: ServerID(rawValue: rawID),
            data: JellyfinServerData(
                serverURL: URL(string: "https://\(rawID).example.test")!,
                serverName: "Server \(rawID)",
                user: UserSnapshot(id: "user-\(rawID)", name: "User", serverLastUpdatedAt: nil)
            ),
            accessToken: "token-\(rawID)"
        )
    }

    @Test("initial destination is bootstrapping until sources are loaded")
    func startsBootstrapping() {
        let router = AppRouter()
        #expect(router.destination == .bootstrapping)
    }

    @Test("a Jellyfin session routes to home and tracks the active server id")
    func tracksActiveServer() {
        let router = AppRouter()
        router.updateForSources(activeSession: session("alpha"), hasAuxiliarySources: false)
        #expect(router.destination == .home)
        #expect(router.activeServerID == ServerID(rawValue: "alpha"))
    }

    // The regression this guards: a switch must CHANGE activeServerID, because
    // RootTabView keys its tab remount on it. The original bug was that nothing
    // updated this on a Servers-tab switch, so the tabs stayed on the old server.
    @Test("a server switch changes activeServerID")
    func switchChangesActiveID() {
        let router = AppRouter()
        router.updateForSources(activeSession: session("alpha"), hasAuxiliarySources: false)
        router.updateForSources(activeSession: session("beta"), hasAuxiliarySources: false)
        #expect(router.activeServerID == ServerID(rawValue: "beta"))
    }

    @Test("no source at all routes to login and clears activeServerID")
    func emptyConfigRoutesToLogin() {
        let router = AppRouter()
        router.updateForSources(activeSession: session("alpha"), hasAuxiliarySources: false)
        router.updateForSources(activeSession: nil, hasAuxiliarySources: false)
        #expect(router.destination == .login)
        #expect(router.activeServerID == nil)
    }

    // The SMB-only unblock: no Jellyfin session, but an auxiliary (SMB) source present, routes to
    // home with a nil activeServerID (the Jellyfin remount key stays nil; the SMB libraries render).
    @Test("an SMB-only config routes to home with a nil activeServerID")
    func smbOnlyRoutesToHome() {
        let router = AppRouter()
        router.updateForSources(activeSession: nil, hasAuxiliarySources: true)
        #expect(router.destination == .home)
        #expect(router.activeServerID == nil)
        #expect(router.hasAnySource)
    }

    // Signing out the last Jellyfin server while an SMB source remains falls back to SMB-only home,
    // NOT login — the user still has a browsable source.
    @Test("losing the Jellyfin session with an SMB source remaining stays on home")
    func jellyfinSignOutFallsBackToSMBHome() {
        let router = AppRouter()
        router.updateForSources(activeSession: session("alpha"), hasAuxiliarySources: true)
        router.updateForSources(activeSession: nil, hasAuxiliarySources: true)
        #expect(router.destination == .home)
        #expect(router.activeServerID == nil)
    }

    // Regression: the roots render during `.bootstrapping` and their library `.task` fires once
    // BEFORE the store resolves — with no source it caches empty entries. For an SMB-only config the
    // active id stays nil and the revision stays 0 across bootstrap→home, so the reload token MUST
    // still change (via the aux-source flag) or that empty result sticks (the empty-sidebar bug).
    @Test("the library reload token moves when SMB-only sources arrive")
    func libraryTokenMovesForSMBOnly() {
        let router = AppRouter()
        let bootToken = router.libraryReloadToken
        router.updateForSources(activeSession: nil, hasAuxiliarySources: true)
        #expect(router.libraryReloadToken != bootToken)
    }

    // The floating settings panel is presented from the stable RootView; it must not be
    // left floating over the bare login root once the last source signs out.
    @Test("dropping to login dismisses the settings panel")
    func loginDismissesSettings() {
        let router = AppRouter()
        router.updateForSources(activeSession: session("alpha"), hasAuxiliarySources: false)
        router.presentingSettings = true
        router.updateForSources(activeSession: nil, hasAuxiliarySources: false)
        #expect(router.presentingSettings == false)
    }

    // But falling back to SMB-only home keeps the user in-app, so the panel must NOT be
    // force-dismissed there (they're still managing real sources).
    @Test("falling back to SMB-only home keeps the settings panel")
    func smbOnlyKeepsSettingsPanel() {
        let router = AppRouter()
        router.updateForSources(activeSession: session("alpha"), hasAuxiliarySources: true)
        router.presentingSettings = true
        router.updateForSources(activeSession: nil, hasAuxiliarySources: true)
        #expect(router.presentingSettings == true)
    }
}
