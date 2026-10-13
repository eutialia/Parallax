import ParallaxCore
import ParallaxFeatures
import ParallaxJellyfinTestSupport
import Testing

@MainActor
@Suite("Home", .timeLimit(.minutes(1)))
struct HomeScenarios {
    @Test("Continue Watching and Next Up show the server's items, most recently watched first")
    func shelvesShowTheServersItems() async throws {
        let den = FakeJellyfinServer(name: "Den").user("ana")
            .library("Films").library("Shows", of: .shows)
            .movie("Arrival", in: "Films").movie("Heat", in: "Films")
            .series("Severance", in: "Shows", episodes: [3]).series("Andor", in: "Shows", episodes: [2])
            .watch("Heat", minutes: 40).finish("Severance S1E1")
            .watch("Arrival", minutes: 10).finish("Andor S1E1")
        let world = try await AppWorld.launch(signedIn: [(den, "ana")])

        try await world.openHome()

        #expect(world.continueWatching == ["Arrival", "Heat"])
        #expect(world.nextUp == ["Andor S1E2", "Severance S1E2"])
    }

    @Test("on Apple TV the launch reveal waits for the library list as well as Home, and opens once both have settled")
    func launchWaitsForHomeAndLibraries() async throws {
        let den = FakeJellyfinServer(name: "Den").user("ana").library("Films")
            .movie("Arrival", in: "Films").watch("Arrival", minutes: 10)
        den.holdResponses(to: .libraryList)
        let world = try await AppWorld.launch(signedIn: [(den, "ana")], launchReveal: .homeAndLibraries)

        let loading = Task { try await world.openHome() }
        try await world.until { world.continueWatching == ["Arrival"] && world.app.home?.isRefreshing == false }
        #expect(world.app.launchGate.releasedAtRawTime == nil)
        #expect(!world.app.isContentReady)

        den.releaseResponses()
        try await loading.value

        #expect(world.app.launchGate.releasedAtRawTime != nil)
        #expect(world.app.isContentReady)
        #expect(world.sidebar == [AppWorld.SidebarSection(title: "Libraries", libraries: ["Films"])])
    }

    @Test("on iPhone and iPad the launch reveal opens once Home has settled, without waiting for the library list")
    func launchRevealsOnHome() async throws {
        let den = FakeJellyfinServer(name: "Den").user("ana").library("Films")
            .movie("Arrival", in: "Films").watch("Arrival", minutes: 10)
        den.holdResponses(to: .libraryList)
        let world = try await AppWorld.launch(signedIn: [(den, "ana")], launchReveal: .home)

        let loading = Task { try await world.openHome() }
        try await world.until { world.continueWatching == ["Arrival"] && world.app.launchGate.releasedAtRawTime != nil }
        #expect(world.app.isContentReady)
        #expect(world.sidebar.isEmpty)

        den.releaseResponses()
        try await loading.value
        #expect(world.sidebar == [AppWorld.SidebarSection(title: "Libraries", libraries: ["Films"])])
    }

    @Test("a relaunch shows the last feed while the server is still answering, then replaces it with the fresh one")
    func cachedFeedShowsBeforeTheNetwork() async throws {
        let den = FakeJellyfinServer(name: "Den").user("ana").library("Films")
            .movie("Arrival", in: "Films").movie("Heat", in: "Films")
            .watch("Arrival", minutes: 10)
        let world = try await AppWorld.launch(signedIn: [(den, "ana")])
        try await world.openHome()
        #expect(world.continueWatching == ["Arrival"])

        den.watch("Heat", minutes: 5)
        den.holdResponses()
        await world.relaunch()
        let loading = Task { try await world.openHome() }
        try await world.until { world.continueWatching == ["Arrival"] }

        den.releaseResponses()
        try await loading.value

        #expect(world.continueWatching == ["Heat", "Arrival"])
    }

    @Test("a source change that leaves the signed-in servers alone keeps Home's shelves without reloading them")
    func unrelatedSourceChangeKeepsHome() async throws {
        let den = FakeJellyfinServer(name: "Den").user("ana").library("Films").library("Shows", of: .shows)
            .movie("Heat", in: "Films").watch("Heat", minutes: 40)
        let world = try await AppWorld.launch(signedIn: [(den, "ana")])
        try await world.openHome()
        let shown = try #require(world.app.home)

        den.watch("Heat", minutes: 50)
        let libraries = VisibleLibrariesModel(session: try await world.session(on: den), app: world.app)
        await libraries.load()
        await libraries.toggle(try #require(libraries.collections.last))
        try await world.openHome()

        #expect(world.app.home === shown)
        #expect(world.minutesWatched("Heat") == 40)
        #expect(world.sidebar == [AppWorld.SidebarSection(title: "Libraries", libraries: ["Films"])])
    }

    @Test("signing in to the same server again rebuilds Home on the new session")
    func reSignInRebuildsHome() async throws {
        let den = FakeJellyfinServer(name: "Den").user("ana").library("Films").library("Shows", of: .shows)
            .movie("Heat", in: "Films").watch("Heat", minutes: 40)
        let world = try await AppWorld.launch(signedIn: [(den, "ana")])
        try await world.openHome()
        let shown = try #require(world.app.home)
        #expect(world.minutesWatched("Heat") == 40)

        try await world.app.signIn(server: den.url, username: "ana", password: "")
        den.watch("Heat", minutes: 50)
        try await world.openHome()

        #expect(world.app.home !== shown)
        try await world.until { world.minutesWatched("Heat") == 50 }
    }

    @Test("with two servers, Continue Watching merges both into one timeline")
    func twoServersMerge() async throws {
        let den = FakeJellyfinServer(name: "Den").user("ana").library("Films")
            .movie("Heat", in: "Films").movie("Ronin", in: "Films")
        let attic = FakeJellyfinServer(name: "Attic").user("bo").library("Movies")
            .movie("Arrival", in: "Movies")
        den.watch("Heat", minutes: 40)
        attic.watch("Arrival", minutes: 10)
        den.watch("Ronin", minutes: 5)
        let world = try await AppWorld.launch(signedIn: [(den, "ana"), (attic, "bo")])

        try await world.openHome()

        #expect(world.continueWatching == ["Ronin", "Arrival", "Heat"])
    }

    @Test("one server being down keeps the other's rows, and its rows come back once it is online again")
    func downServerKeepsTheOthersRows() async throws {
        let den = FakeJellyfinServer(name: "Den").user("ana").library("Films").movie("Heat", in: "Films")
        let attic = FakeJellyfinServer(name: "Attic").user("bo").library("Movies").movie("Arrival", in: "Movies")
        den.watch("Heat", minutes: 40)
        attic.watch("Arrival", minutes: 10)
        attic.goOffline()
        let world = try await AppWorld.launch(signedIn: [(den, "ana"), (attic, "bo")])

        try await world.openHome()

        #expect(world.app.home?.state == .loaded)
        #expect(world.continueWatching == ["Heat"])
        #expect(world.app.home?.needsOfflineRepair == true)

        attic.comeBackOnline()
        await world.app.home?.recoverFromOffline()

        #expect(world.continueWatching == ["Arrival", "Heat"])
        #expect(world.app.home?.needsOfflineRepair == false)
    }

    @Test("every server down shows Home's failure, not an empty feed")
    func everyServerDownFailsHome() async throws {
        let den = FakeJellyfinServer(name: "Den").user("ana")
        den.goOffline()
        let world = try await AppWorld.launch(signedIn: [(den, "ana")])

        try await world.openHome()

        #expect(world.app.home?.state == .failed("Parallax couldn't reach your servers."))
    }

    @Test("playing a Continue Watching movie and closing the player shows its new progress")
    func dismissingThePlayerRefreshesProgress() async throws {
        let den = FakeJellyfinServer(name: "Den").user("ana").library("Films")
            .movie("Arrival", in: "Films").movie("Heat", in: "Films")
            .watch("Arrival", minutes: 10).watch("Heat", minutes: 40)
        let world = try await AppWorld.launch(signedIn: [(den, "ana")])
        try await world.openHome()
        #expect(world.continueWatching == ["Heat", "Arrival"])
        let session = try await world.session(on: den)
        let arrival = try #require(world.app.home?.continueWatching.last)

        guard case .play(let itemID) = MediaTileTap.resolve(arrival.item, on: session, moviePlays: true) else {
            Issue.record("a Continue Watching movie opened its detail instead of playing")
            return
        }
        world.app.playback.play(itemID, in: session)
        den.watch("Arrival", minutes: 55)
        world.app.playback.dismiss()

        try await world.until { world.continueWatching == ["Arrival", "Heat"] }
        #expect(world.minutesWatched("Arrival") == 55)
    }
}
