import Foundation
import Testing
import JellyfinAPI
import ParallaxCore
@testable import ParallaxJellyfin

@Suite("LibraryRepository — drill-in + home + search")
struct LibraryRepositoryDrillInTests {
    private func make() -> (LibraryRepository, FakeJellyfinLibraryClient) {
        let session = Session(
            persisted: PersistedSession(
                id: ServerID(rawValue: "s1"),
                serverURL: URL(string: "https://j.example.com")!,
                serverName: "Home",
                user: UserSnapshot(id: "u1", name: "alice", serverLastUpdatedAt: nil)
            ),
            accessToken: "tok-1"
        )
        let client = FakeJellyfinLibraryClient()
        return (LibraryRepository(session: session, client: client), client)
    }

    private func dtoSeason(_ id: String, seriesID: String) -> BaseItemDto {
        var d = BaseItemDto()
        d.id = id; d.name = "Season \(id)"; d.type = .season
        d.seriesID = seriesID
        d.indexNumber = 1
        return d
    }

    private func dtoEpisode(_ id: String, seriesID: String, seasonID: String) -> BaseItemDto {
        var d = BaseItemDto()
        d.id = id; d.name = "Episode \(id)"; d.type = .episode
        d.seriesID = seriesID; d.seasonID = seasonID
        d.indexNumber = 1; d.parentIndexNumber = 1
        return d
    }

    private func dtoMovie(_ id: String) -> BaseItemDto {
        var d = BaseItemDto()
        d.id = id; d.name = "Movie \(id)"; d.type = .movie
        return d
    }

    @Test("seasons(of:) translates and forwards seriesID")
    func seasons() async throws {
        let (repo, client) = make()
        client.seasonsResult = .success([
            dtoSeason("se1", seriesID: "ser1"),
            dtoSeason("se2", seriesID: "ser1"),
        ])
        let seasons = try await repo.seasons(of: ItemID(rawValue: "ser1"))
        #expect(seasons.count == 2)
        #expect(seasons.allSatisfy { $0.seriesID == ItemID(rawValue: "ser1") })
        #expect(client.seasonsCalls == ["ser1"])
    }

    @Test("episodes(of:) translates and forwards seasonID")
    func episodes() async throws {
        let (repo, client) = make()
        client.episodesResult = .success([
            dtoEpisode("e1", seriesID: "ser1", seasonID: "se1"),
        ])
        let eps = try await repo.episodes(of: ItemID(rawValue: "se1"))
        #expect(eps.count == 1)
        #expect(eps.first?.seasonID == ItemID(rawValue: "se1"))
        #expect(client.episodesCalls == ["se1"])
    }

    @Test("continueWatching() returns a mixed Item array")
    func continueWatching() async throws {
        let (repo, client) = make()
        client.continueWatchingResult = .success([
            dtoMovie("m1"),
            dtoEpisode("e1", seriesID: "ser1", seasonID: "se1"),
        ])
        let items = try await repo.continueWatching()
        #expect(items.count == 2)
        if case .movie = items.first { } else { Issue.record("first should be .movie") }
        if case .episode = items.last { } else { Issue.record("last should be .episode") }
    }

    @Test("nextUp() returns Episode items")
    func nextUp() async throws {
        let (repo, client) = make()
        client.nextUpResult = .success([
            dtoEpisode("e1", seriesID: "ser1", seasonID: "se1"),
        ])
        let items = try await repo.nextUp()
        #expect(items.count == 1)
        if case .episode = items.first { } else { Issue.record("expected .episode") }
    }

    @Test("search(.all) fans out to three per-type calls and merges results")
    func searchAllFansOut() async throws {
        let (repo, client) = make()
        var seriesDto = BaseItemDto()
        seriesDto.id = "ser1"; seriesDto.name = "Breaking Bad"; seriesDto.type = .series
        client.searchResultsByScope = [
            .movies: .success([dtoMovie("m1")]),
            .series: .success([seriesDto]),
            .episodes: .success([dtoEpisode("e1", seriesID: "ser1", seasonID: "se1")]),
        ]
        let results = try await repo.search("bad", scope: .all)
        #expect(results.movies.count == 1)
        #expect(results.series.count == 1)
        #expect(results.episodes.count == 1)
        // Three independent calls, never .all — that's the whole point: a
        // single combined query lets episode floods crowd series out, which
        // is what we saw against the user's anime library.
        #expect(client.searchCalls.count == 3)
        let scopes = Set(client.searchCalls.map { $0.scope })
        #expect(scopes == [.movies, .series, .episodes])
        #expect(client.searchCalls.allSatisfy { $0.query == "bad" })
    }

    @Test("search(.all) surfaces series even when episodes flood results")
    func searchAllSeriesNotCrowdedOut() async throws {
        let (repo, client) = make()
        var seriesDto = BaseItemDto()
        seriesDto.id = "ser1"; seriesDto.name = "Hyouka"; seriesDto.type = .series
        let manyEpisodes = (0..<50).map { dtoEpisode("e\($0)", seriesID: "ser1", seasonID: "se1") }
        client.searchResultsByScope = [
            .movies: .success([]),
            .series: .success([seriesDto]),
            .episodes: .success(manyEpisodes),
        ]
        let results = try await repo.search("hyouka", scope: .all)
        // Regression: previously a single combined query with limit=50 let
        // 50 episode hits push the series out of the response entirely.
        #expect(results.series.count == 1)
        #expect(results.series.first?.title == "Hyouka")
        #expect(results.episodes.count == 50)
    }

    @Test("search(.series) only calls the series scope")
    func searchSeriesScope() async throws {
        let (repo, client) = make()
        var s = BaseItemDto(); s.id = "ser1"; s.name = "X"; s.type = .series
        client.searchResultsByScope = [.series: .success([s])]
        let results = try await repo.search("x", scope: .series)
        #expect(results.series.count == 1)
        #expect(results.movies.isEmpty)
        #expect(results.episodes.isEmpty)
        #expect(client.searchCalls.count == 1)
        #expect(client.searchCalls.first?.scope == .series)
    }

    @Test("search() with whitespace-only query short-circuits without calling client")
    func searchEmpty() async throws {
        let (repo, client) = make()
        let results = try await repo.search("   ", scope: .all)
        #expect(results.movies.isEmpty)
        #expect(results.series.isEmpty)
        #expect(results.episodes.isEmpty)
        #expect(client.searchCalls.isEmpty)
    }
}
