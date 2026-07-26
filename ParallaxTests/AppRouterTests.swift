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

    /// A snapshot the way `ServerStore.sourceSnapshot` builds one: the active session's id, whether
    /// any auxiliary source exists, and an order-sensitive fingerprint of every configured source
    /// marked live (`+`) or signed-out (`-`).
    private func snapshot(
        active: String?,
        jellyfin: [String] = [],
        smb: [String] = [],
        signedOutJellyfin: [String] = []
    ) -> SourceSnapshot {
        let live = jellyfin.map { "\($0)+" } + smb.map { "\($0)+" }
        let dead = signedOutJellyfin.map { "\($0)-" }
        return SourceSnapshot(
            activeSessionID: active.map { ServerID(rawValue: $0) },
            hasAuxiliarySources: !smb.isEmpty,
            setIdentity: (live + dead).joined(separator: ",")
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
        router.updateForSources(snapshot(active: "alpha", jellyfin: ["alpha"]))
        #expect(router.destination == .home)
        #expect(router.activeServerID == ServerID(rawValue: "alpha"))
    }

    // The regression this guards: a switch must CHANGE activeServerID, because
    // RootTabView keys its tab remount on it. The original bug was that nothing
    // updated this on a Servers-tab switch, so the tabs stayed on the old server.
    @Test("a server switch changes activeServerID")
    func switchChangesActiveID() {
        let router = AppRouter()
        router.updateForSources(snapshot(active: "alpha", jellyfin: ["alpha", "beta"]))
        router.updateForSources(snapshot(active: "beta", jellyfin: ["alpha", "beta"]))
        #expect(router.activeServerID == ServerID(rawValue: "beta"))
    }

    @Test("no source at all routes to login and clears activeServerID")
    func emptyConfigRoutesToLogin() {
        let router = AppRouter()
        router.updateForSources(snapshot(active: "alpha", jellyfin: ["alpha"]))
        router.updateForSources(snapshot(active: nil))
        #expect(router.destination == .login)
        #expect(router.activeServerID == nil)
    }

    // The SMB-only unblock: no Jellyfin session, but an auxiliary (SMB) source present, routes to
    // home with a nil activeServerID (the Jellyfin remount key stays nil; the SMB libraries render).
    @Test("an SMB-only config routes to home with a nil activeServerID")
    func smbOnlyRoutesToHome() {
        let router = AppRouter()
        router.updateForSources(snapshot(active: nil, smb: ["smb-nas"]))
        #expect(router.destination == .home)
        #expect(router.activeServerID == nil)
        #expect(router.hasAnySource)
    }

    // Signing out the last Jellyfin server while an SMB source remains falls back to SMB-only home,
    // NOT login — the user still has a browsable source.
    @Test("losing the Jellyfin session with an SMB source remaining stays on home")
    func jellyfinSignOutFallsBackToSMBHome() {
        let router = AppRouter()
        router.updateForSources(snapshot(active: "alpha", jellyfin: ["alpha"], smb: ["smb-nas"]))
        router.updateForSources(snapshot(active: nil, smb: ["smb-nas"]))
        #expect(router.destination == .home)
        #expect(router.activeServerID == nil)
    }

    // MARK: - Library reload token

    // Regression: the roots render during `.bootstrapping` and their library `.task` fires once
    // BEFORE the store resolves — with no source it caches empty entries. For an SMB-only config the
    // active id stays nil and the revision stays 0 across bootstrap→home, so the reload token MUST
    // still change (via the source-set fingerprint) or that empty result sticks (empty-sidebar bug).
    @Test("the library reload token moves when SMB-only sources arrive")
    func libraryTokenMovesForSMBOnly() {
        let router = AppRouter()
        let bootToken = router.libraryReloadToken
        router.updateForSources(snapshot(active: nil, smb: ["smb-nas"]))
        #expect(router.libraryReloadToken != bootToken)
    }

    // THE multi-server bug (found on device): adding a SECOND Jellyfin server left the first one
    // active and involved no SMB source, so neither `activeServerID` nor the auxiliary flag moved
    // and the roots' `.task(id:)` never re-fired — the new server's libraries were missing from the
    // sidebar until the app was relaunched. The source-set fingerprint is what makes it visible.
    @Test("adding a second Jellyfin server moves the reload token even though the active server doesn't")
    func libraryTokenMovesWhenSecondJellyfinServerAdded() {
        let router = AppRouter()
        router.updateForSources(snapshot(active: "alpha", jellyfin: ["alpha"]))
        let oneServer = router.libraryReloadToken

        router.updateForSources(snapshot(active: "alpha", jellyfin: ["alpha", "beta"]))

        #expect(router.libraryReloadToken != oneServer)
        // ...and the active server is deliberately unchanged, which is exactly why the old
        // activeServerID-only token couldn't see this.
        #expect(router.activeServerID == ServerID(rawValue: "alpha"))
    }

    // The mirror-image case: signing out a NON-active Jellyfin server also leaves the active id
    // alone, so without the fingerprint its section would linger in the sidebar.
    @Test("signing out a non-active Jellyfin server moves the reload token")
    func libraryTokenMovesWhenNonActiveServerSignedOut() {
        let router = AppRouter()
        router.updateForSources(snapshot(active: "alpha", jellyfin: ["alpha", "beta"]))
        let twoServers = router.libraryReloadToken

        router.updateForSources(snapshot(active: "alpha", jellyfin: ["alpha"]))

        #expect(router.libraryReloadToken != twoServers)
        #expect(router.activeServerID == ServerID(rawValue: "alpha"))
    }

    // Re-signing into a server whose Keychain token was lost keeps the SAME persisted id, so only
    // the live/signed-out marker changes — but the roots must still rebuild, because that row goes
    // from contributing no libraries to contributing its collections.
    @Test("re-signing into a signed-out server moves the reload token")
    func libraryTokenMovesWhenSignedOutServerHeals() {
        let router = AppRouter()
        router.updateForSources(snapshot(active: "alpha", jellyfin: ["alpha"], signedOutJellyfin: ["beta"]))
        let withSignedOutRow = router.libraryReloadToken

        router.updateForSources(snapshot(active: "alpha", jellyfin: ["alpha", "beta"]))

        #expect(router.libraryReloadToken != withSignedOutRow)
    }

    // `libraryRevision` still covers what no source fingerprint can see: a change to the CONTENTS
    // of an unchanged source set (a "Visible Libraries" edit, an SMB share re-selection).
    @Test("a revision bump moves the token with the source set unchanged")
    func libraryTokenMovesOnRevisionBump() {
        let router = AppRouter()
        router.updateForSources(snapshot(active: "alpha", jellyfin: ["alpha"]))
        let before = router.libraryReloadToken

        router.bumpLibraryRevision()

        #expect(router.libraryReloadToken != before)
    }

    // MARK: - Settings panel

    // The floating settings panel is presented from the stable RootView; it must not be
    // left floating over the bare login root once the last source signs out.
    @Test("dropping to login dismisses the settings panel")
    func loginDismissesSettings() {
        let router = AppRouter()
        router.updateForSources(snapshot(active: "alpha", jellyfin: ["alpha"]))
        router.presentingSettings = true
        router.updateForSources(snapshot(active: nil))
        #expect(router.presentingSettings == false)
    }

    // But falling back to SMB-only home keeps the user in-app, so the panel must NOT be
    // force-dismissed there (they're still managing real sources).
    @Test("falling back to SMB-only home keeps the settings panel")
    func smbOnlyKeepsSettingsPanel() {
        let router = AppRouter()
        router.updateForSources(snapshot(active: "alpha", jellyfin: ["alpha"], smb: ["smb-nas"]))
        router.presentingSettings = true
        router.updateForSources(snapshot(active: nil, smb: ["smb-nas"]))
        #expect(router.presentingSettings == true)
    }
}
