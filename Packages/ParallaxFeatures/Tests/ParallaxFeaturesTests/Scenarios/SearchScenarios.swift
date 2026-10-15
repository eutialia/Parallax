import ParallaxCore
@testable import ParallaxFeatures
import ParallaxJellyfinTestSupport
import Testing
import ParallaxTestScaling

@MainActor
@Suite("Search", .scaledTimeLimit())
struct SearchScenarios {
    @Test("typing a query shows nothing until the typing settles, then the matches")
    func resultsArriveAfterTheDebounce() async throws {
        let (world, search, _) = try await openSearch()

        search.query = "the"
        try await world.clock.waitForSleep(dueIn: .milliseconds(350))
        #expect(search.state == .idle)
        world.clock.advance(by: .milliseconds(350))

        try await world.until { titles(search) == Titles(movies: ["The Thing"], series: ["The Bear"]) }
    }

    @Test("narrowing the scope to Movies keeps only the movies")
    func scopeFiltersResults() async throws {
        let (world, search, _) = try await openSearch()
        search.query = "the"
        try await world.settleTyping()
        try await world.until { titles(search) == Titles(movies: ["The Thing"], series: ["The Bear"]) }

        search.scope = .movies
        try await world.settleTyping()

        try await world.until { titles(search) == Titles(movies: ["The Thing"], series: []) }
    }

    @Test("clearing the field ends the search session and puts the scope back to All")
    func clearingResetsTheScope() async throws {
        let (world, search, _) = try await openSearch()
        search.query = "the"
        try await world.settleTyping()
        try await world.until { titles(search) == Titles(movies: ["The Thing"], series: ["The Bear"]) }
        search.scope = .series
        try await world.settleTyping()
        try await world.until { titles(search) == Titles(movies: [], series: ["The Bear"]) }

        search.query = ""
        try await world.settleTyping()

        try await world.until { !search.hasActiveSearch }
        #expect(search.scope == .all)
    }

    @Test("signing into a second server mid-search puts the scope back to All and searches both servers")
    func newServerResetsTheScope() async throws {
        let (world, search, _) = try await openSearch()
        let attic = FakeJellyfinServer(name: "Attic").user("bo").library("Movies").movie("The Fly", in: "Movies")
        search.query = "the"
        try await world.settleTyping()
        try await world.until { titles(search) == Titles(movies: ["The Thing"], series: ["The Bear"]) }
        search.scope = .movies
        try await world.settleTyping()
        try await world.until { titles(search) == Titles(movies: ["The Thing"], series: []) }

        try await world.app.signIn(server: attic.url, username: "bo", password: "")
        try await world.until { search.scope == .all }
        try await world.settleTyping()

        try await world.until { titles(search) == Titles(movies: ["The Thing", "The Fly"], series: ["The Bear"]) }
    }

    @Test("a search the server can't answer fails with a retry, and the retry shows the matches once it is back")
    func failedSearchRetries() async throws {
        let (world, search, den) = try await openSearch()
        den.goOffline()

        search.query = "the"
        try await world.settleTyping()

        try await world.until { search.isStalled }
        #expect(search.state == .failed("Parallax couldn't reach your servers."))

        den.comeBackOnline()
        await search.retry()

        #expect(titles(search) == Titles(movies: ["The Thing"], series: ["The Bear"]))
    }

    @Test("a query that runs before the servers are known shows the skeleton, and the matches follow once they are")
    func queryBeforeTheServersAreKnownDoesNotReportNoResults() async throws {
        let den = FakeJellyfinServer(name: "Den").user("ana")
            .library("Films").movie("The Thing", in: "Films")
        let world = try await AppWorld.launch(signedIn: [(den, "ana")])
        let search = JellyfinSearchViewModel(app: world.app)

        search.query = "the"
        await search.retry()
        #expect(search.state == .loading)

        world.mount { await search.run() }

        try await world.until { titles(search) == Titles(movies: ["The Thing"], series: []) }
    }

    private func openSearch() async throws -> (AppWorld, JellyfinSearchViewModel, FakeJellyfinServer) {
        let den = FakeJellyfinServer(name: "Den").user("ana")
            .library("Films").library("Shows", of: .shows)
            .movie("The Thing", in: "Films").movie("Heat", in: "Films")
            .series("The Bear", in: "Shows", episodes: [])
        let world = try await AppWorld.launch(signedIn: [(den, "ana")])
        let search = JellyfinSearchViewModel(app: world.app)
        world.mount { await search.run() }
        try await world.until { !search.sourceIDs.isEmpty }
        return (world, search, den)
    }

    private struct Titles: Equatable {
        let movies: [String]
        let series: [String]
    }

    private func titles(_ search: JellyfinSearchViewModel) -> Titles? {
        guard case .loaded(let results) = search.state else { return nil }
        return Titles(movies: results.movies.map(\.item.displayTitle), series: results.series.map(\.item.displayTitle))
    }
}

private extension AppWorld {
    /// The user stops typing: the debounce runs out.
    func settleTyping() async throws {
        try await clock.waitForSleep(dueIn: .milliseconds(350))
        clock.advance(by: .milliseconds(350))
    }
}
