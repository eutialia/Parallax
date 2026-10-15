import Foundation
import ParallaxCore
import ParallaxFeatures
import ParallaxFileBrowse
import ParallaxJellyfin
import ParallaxJellyfinTestSupport
import Testing
import ParallaxTestScaling

@MainActor
@Suite("Offline recovery and foreground return", .scaledTimeLimit())
struct RecoveryScenarios {
    private struct NASUnreachable: Error {}

    private static func file(_ name: String) -> SMBDirectoryEntry {
        SMBDirectoryEntry(name: name, isDirectory: false, size: 1, modifiedAt: nil)
    }

    private static func den() -> FakeJellyfinServer {
        FakeJellyfinServer(name: "Den").user("ana").library("Films")
            .movie("Heat", in: "Films").watch("Heat", minutes: 40)
    }

    @Test("a Home that failed while offline reloads by itself when the network returns")
    func homeReloadsWhenTheNetworkReturns() async throws {
        let den = Self.den()
        den.goOffline()
        let world = try await AppWorld.launch(signedIn: [(den, "ana")])
        try await world.goOffline()
        try await world.openHome()
        #expect(world.app.home?.state == .failed("Parallax couldn't reach your servers."))

        den.comeBackOnline()
        try await world.comeOnline()

        try await world.until { world.continueWatching == ["Heat"] }
        #expect(world.app.home?.state == .loaded)
    }

    @Test("sidebar libraries that failed while offline come back when the network returns")
    func sidebarLibrariesComeBackOnReconnect() async throws {
        let den = Self.den()
        den.goOffline()
        let world = try await AppWorld.launch(signedIn: [(den, "ana")])
        try await world.goOffline()
        try await world.openHome()
        #expect(world.sidebar.isEmpty)

        den.comeBackOnline()
        try await world.comeOnline()

        try await world.until { world.sidebar == [AppWorld.SidebarSection(title: "Libraries", libraries: ["Films"])] }
    }

    @Test("a library reload still in flight when the last server signs out leaves the login's empty list alone")
    func reloadInFlightAtSignOutCommitsNothing() async throws {
        let den = Self.den()
        den.goOffline()
        let world = try await AppWorld.launch(signedIn: [(den, "ana")])
        try await world.goOffline()
        try await world.openHome()
        #expect(world.app.libraries.failedSourceNames == ["Den"])
        den.comeBackOnline()
        den.holdResponses(to: .libraryList)
        try await world.comeOnline()
        try await world.until { den.heldResponseCount == 1 }
        let settings = SettingsViewModel(app: world.app)
        await settings.refresh()
        let session = try #require(settings.sessions.first)

        await settings.signOut(session)
        den.releaseResponses()
        // A request sent after the release answers after it, so the reload has settled by then.
        await world.app.movieDetail(ItemID(rawValue: den.itemID(of: "Heat")), on: session).load()

        #expect(world.app.router.destination == .login)
        #expect(world.app.libraries.isResolving)
        #expect(world.app.libraries.failedSourceNames.isEmpty)
    }

    @Test("a Home that failed because its server was down reloads when the user returns to the app")
    func homeReloadsOnReturnFromBackground() async throws {
        let den = Self.den()
        den.goOffline()
        let world = try await AppWorld.launch(signedIn: [(den, "ana")])
        try await world.openHome()
        #expect(world.app.home?.state == .failed("Parallax couldn't reach your servers."))

        world.background()
        den.comeBackOnline()
        world.foreground()

        try await world.until { world.continueWatching == ["Heat"] }
        #expect(world.app.home?.state == .loaded)
    }

    @Test("returning from the background to an SMB folder flushes the idle connections and lists the folder again")
    func smbFolderRelistsAfterReturn() async throws {
        let world = try await AppWorld.launch(savedSMB: [(AppWorld.smbServer, "hunter2")])
        world.nas.setFolder([Self.file("Alien.mp4")], share: "Media")
        let root = await world.openSMBFolder(AppWorld.smbRef, share: "Media")
        try await world.until { root.media.map { $0.displayTitle } == ["Alien"] }
        let idleBefore = world.nas.connectedIDs

        world.nas.setFolder([Self.file("Alien.mp4"), Self.file("Brazil.avi")], share: "Media")
        world.background()
        world.foreground()

        try await world.until { root.media.map { $0.displayTitle } == ["Alien", "Brazil"] }
        #expect(world.nas.disconnectedIDs == idleBefore)
        #expect(world.nas.connectedIDs.count == idleBefore.count + 1)
        #expect(world.nas.listedPaths == ["/", "/"])
    }

    @Test("a cold launch's first activation is not a return from the background: the stalled share root is listed once")
    func coldLaunchActivationDoesNotRelist() async throws {
        let world = try await AppWorld.launch(savedSMB: [(AppWorld.smbServer, "hunter2")])
        world.nas.setListingOutcome(.fails(NASUnreachable()))
        let root = await world.openSMBFolder(AppWorld.smbRef, share: "Media")
        try await world.until { root.isStalled }

        // Both re-list flows key on this edge, and it moves synchronously: zero means neither runs.
        world.settleLaunch()

        #expect(world.app.lifecycle.foregroundReturns == 0)

        world.nas.setListingOutcome(.entries([Self.file("Alien.mp4")]))
        world.background()
        world.foreground()

        try await world.until { root.media.map { $0.displayTitle } == ["Alien"] }
        #expect(world.app.lifecycle.foregroundReturns == 1)
    }

    @Test("returning from the background lists a stalled SMB folder once, and re-lists the healthy one beside it")
    func stalledFolderIsListedOnceOnReturn() async throws {
        let world = try await AppWorld.launch(savedSMB: [(AppWorld.smbServer, "hunter2")])
        world.nas.setFolder([Self.file("Alien.mp4")], share: "Media")
        world.nas.setListingOutcome(.fails(NASUnreachable()))
        let root = await world.openSMBFolder(AppWorld.smbRef, share: "Media")
        let movies = await world.openSMBFolder(AppWorld.smbRef, share: "Media", path: "Movies")
        try await world.until { root.media.map { $0.displayTitle } == ["Alien"] && movies.isStalled }
        world.settleLaunch()

        world.nas.setFolder([Self.file("Brazil.avi")], share: "Media", path: "Movies")
        world.background()
        world.foreground()

        // The healthy root's re-list starts in the same step that would re-list a recovered folder.
        try await world.until { () async in world.nas.listedPaths.filter { $0 == "/" }.count == 2 }
        try await world.until { movies.media.map { $0.displayTitle } == ["Brazil"] }
        #expect(!movies.isRefreshing)
        #expect(world.nas.listedPaths.filter { $0 != "/" } == ["Movies", "Movies"])
    }
}
