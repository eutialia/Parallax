import Testing
import Foundation
import ParallaxJellyfin
@testable import Parallax

/// A snapshot the way `ServerStore.sourceSnapshot` builds one: the active session's id, whether any
/// auxiliary source exists, and an order-sensitive fingerprint of every configured source marked
/// live (`+`) or signed-out (`-`). File scope (not a member) so the parameterized reload-token table
/// below can be built outside the suite's MainActor isolation.
private func sourceSnapshot(
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

/// One `before → after` source-set transition the roots' `.task(id:)` must notice. Named so a
/// failure reads as the scenario rather than as two fingerprint strings.
struct TokenMove: Sendable, CustomTestStringConvertible {
    let name: String
    let before: SourceSnapshot
    let after: SourceSnapshot
    var testDescription: String { name }
}

private let tokenMoves: [TokenMove] = [
    // Regression: the roots render during `.bootstrapping` and their library `.task` fires once
    // BEFORE the store resolves — with no source it caches empty entries. For an SMB-only config the
    // active id stays nil and the revision stays 0 across bootstrap→home, so the token MUST still
    // change (via the fingerprint) or that empty result sticks (empty-sidebar bug).
    TokenMove(
        name: "SMB-only sources arrive after bootstrap",
        before: .empty,
        after: sourceSnapshot(active: nil, smb: ["smb-nas"])
    ),
    // THE multi-server bug (found on device): adding a SECOND Jellyfin server left the first one
    // active and involved no SMB source, so neither `activeServerID` nor the auxiliary flag moved and
    // the roots' `.task(id:)` never re-fired — the new server's libraries were missing from the
    // sidebar until relaunch. The source-set fingerprint is what makes it visible.
    TokenMove(
        name: "a second Jellyfin server is added, active server unchanged",
        before: sourceSnapshot(active: "alpha", jellyfin: ["alpha"]),
        after: sourceSnapshot(active: "alpha", jellyfin: ["alpha", "beta"])
    ),
    // The mirror-image case: signing out a NON-active Jellyfin server also leaves the active id
    // alone, so without the fingerprint its section would linger in the sidebar.
    TokenMove(
        name: "a non-active Jellyfin server is signed out",
        before: sourceSnapshot(active: "alpha", jellyfin: ["alpha", "beta"]),
        after: sourceSnapshot(active: "alpha", jellyfin: ["alpha"])
    ),
    // Re-signing into a server whose Keychain token was lost keeps the SAME persisted id, so only the
    // live/signed-out marker changes — but the roots must still rebuild, because that row goes from
    // contributing no libraries to contributing its collections.
    TokenMove(
        name: "a signed-out server heals into a live session",
        before: sourceSnapshot(active: "alpha", jellyfin: ["alpha"], signedOutJellyfin: ["beta"]),
        after: sourceSnapshot(active: "alpha", jellyfin: ["alpha", "beta"])
    ),
]

@MainActor
struct AppRouterTests {

    @Test("initial destination is bootstrapping until sources are loaded")
    func startsBootstrapping() {
        let router = AppRouter()
        #expect(router.destination == .bootstrapping)
    }

    @Test("a Jellyfin session routes to home and tracks the active server id")
    func tracksActiveServer() {
        let router = AppRouter()
        router.updateForSources(sourceSnapshot(active: "alpha", jellyfin: ["alpha"]))
        #expect(router.destination == .home)
        #expect(router.activeServerID == ServerID(rawValue: "alpha"))
    }

    // The regression this guards: a switch must CHANGE activeServerID, because
    // RootTabView keys its tab remount on it. The original bug was that nothing
    // updated this on a Servers-tab switch, so the tabs stayed on the old server.
    @Test("a server switch changes activeServerID")
    func switchChangesActiveID() {
        let router = AppRouter()
        router.updateForSources(sourceSnapshot(active: "alpha", jellyfin: ["alpha", "beta"]))
        router.updateForSources(sourceSnapshot(active: "beta", jellyfin: ["alpha", "beta"]))
        #expect(router.activeServerID == ServerID(rawValue: "beta"))
    }

    @Test("no source at all routes to login and clears activeServerID")
    func emptyConfigRoutesToLogin() {
        let router = AppRouter()
        router.updateForSources(sourceSnapshot(active: "alpha", jellyfin: ["alpha"]))
        router.updateForSources(sourceSnapshot(active: nil))
        #expect(router.destination == .login)
        #expect(router.activeServerID == nil)
    }

    // The SMB-only unblock: no Jellyfin session, but an auxiliary (SMB) source present, routes to
    // home with a nil activeServerID (the Jellyfin remount key stays nil; the SMB libraries render).
    @Test("an SMB-only config routes to home with a nil activeServerID")
    func smbOnlyRoutesToHome() {
        let router = AppRouter()
        router.updateForSources(sourceSnapshot(active: nil, smb: ["smb-nas"]))
        #expect(router.destination == .home)
        #expect(router.activeServerID == nil)
        #expect(router.hasAnySource)
    }

    // Signing out the last Jellyfin server while an SMB source remains falls back to SMB-only home,
    // NOT login — the user still has a browsable source.
    @Test("losing the Jellyfin session with an SMB source remaining stays on home")
    func jellyfinSignOutFallsBackToSMBHome() {
        let router = AppRouter()
        router.updateForSources(sourceSnapshot(active: "alpha", jellyfin: ["alpha"], smb: ["smb-nas"]))
        router.updateForSources(sourceSnapshot(active: nil, smb: ["smb-nas"]))
        #expect(router.destination == .home)
        #expect(router.activeServerID == nil)
    }

    // MARK: - Library reload token

    @Test("every change to the source SET moves the library reload token", arguments: tokenMoves)
    func libraryTokenMovesOnSourceSetChange(move: TokenMove) {
        let router = AppRouter()
        router.updateForSources(move.before)
        let before = router.libraryReloadToken

        router.updateForSources(move.after)

        #expect(router.libraryReloadToken != before, "\(move.name) left the roots' reload key put")
        // The active id is deliberately NOT part of what these transitions change (only the SMB-only
        // arrival moves it, and only from nil to nil) — which is exactly why the old
        // activeServerID-only token couldn't see any of them.
        #expect(router.activeServerID == move.after.activeSessionID)
    }

    /// The other half of the contract, and the one no inequality assertion can catch: re-applying an
    /// IDENTICAL snapshot must leave the token PUT. A token that moved on every call would satisfy
    /// every "moves when…" test above while re-firing the roots' `.task(id:)` on every store read —
    /// an endless sidebar reload loop.
    @Test("re-applying the same source set does NOT move the token", arguments: tokenMoves)
    func libraryTokenIsStableForAnUnchangedSourceSet(move: TokenMove) {
        let router = AppRouter()
        router.updateForSources(move.after)
        let settled = router.libraryReloadToken

        router.updateForSources(move.after)

        #expect(router.libraryReloadToken == settled)
    }

    // `libraryRevision` still covers what no source fingerprint can see: a change to the CONTENTS
    // of an unchanged source set (a "Visible Libraries" edit, an SMB share re-selection).
    @Test("a revision bump moves the token with the source set unchanged")
    func libraryTokenMovesOnRevisionBump() {
        let router = AppRouter()
        router.updateForSources(sourceSnapshot(active: "alpha", jellyfin: ["alpha"]))
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
        router.updateForSources(sourceSnapshot(active: "alpha", jellyfin: ["alpha"]))
        router.presentingSettings = true
        router.updateForSources(sourceSnapshot(active: nil))
        #expect(router.presentingSettings == false)
    }

    // But falling back to SMB-only home keeps the user in-app, so the panel must NOT be
    // force-dismissed there (they're still managing real sources).
    @Test("falling back to SMB-only home keeps the settings panel")
    func smbOnlyKeepsSettingsPanel() {
        let router = AppRouter()
        router.updateForSources(sourceSnapshot(active: "alpha", jellyfin: ["alpha"], smb: ["smb-nas"]))
        router.presentingSettings = true
        router.updateForSources(sourceSnapshot(active: nil, smb: ["smb-nas"]))
        #expect(router.presentingSettings == true)
    }
}
