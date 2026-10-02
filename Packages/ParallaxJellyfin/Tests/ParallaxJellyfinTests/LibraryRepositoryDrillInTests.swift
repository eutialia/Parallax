import Foundation
import Testing
import JellyfinAPI
import ParallaxCore
@testable import ParallaxJellyfin

@Suite("LibraryRepository — drill-in + home + search")
struct LibraryRepositoryDrillInTests {
    private func make() -> (LibraryRepository, FakeJellyfinLibraryClient) {
        let client = FakeJellyfinLibraryClient()
        return (LibraryRepository(client: client), client)
    }

    private func dtoSeason(_ id: String, seriesID: String, primaryTag: String? = nil) -> BaseItemDto {
        JellyfinFixtures.seasonDto(
            id: id,
            seriesID: seriesID,
            imageTags: primaryTag.map { ["Primary": $0] }
        )
    }

    private func dtoEpisode(_ id: String, seriesID: String, seasonID: String) -> BaseItemDto {
        JellyfinFixtures.episodeDto(
            id: id,
            seriesID: seriesID,
            seasonID: seasonID,
            indexNumber: 1,
            parentIndexNumber: 1
        )
    }

    private func dtoMovie(_ id: String) -> BaseItemDto {
        JellyfinFixtures.movieDto(id: id)
    }

    private func dtoSeries(_ id: String) -> BaseItemDto {
        JellyfinFixtures.seriesDto(id: id, imageTags: ["Primary": "series-poster"])
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
        client.itemsByIDsResult = .success([dtoSeason("se1", seriesID: "ser1", primaryTag: "season-folder-art")])
        let items = try await repo.continueWatching()
        #expect(items.count == 2)
        if case .movie = items.first { } else { Issue.record("first should be .movie") }
        guard case .episode(let ep) = items.last else {
            Issue.record("last should be .episode")
            return
        }
        #expect(ep.seasonImageRef?.itemID.rawValue == "se1")
        #expect(ep.seasonImageRef?.tag.rawValue == "season-folder-art")
        #expect(Set(client.itemsByIDsCalls.last ?? []) == Set(["se1", "ser1"]))
    }

    @Test("continueWatching() uses series poster when season has no primary")
    func continueWatchingSeriesFallback() async throws {
        let (repo, client) = make()
        client.continueWatchingResult = .success([
            dtoEpisode("e1", seriesID: "ser1", seasonID: "se1"),
        ])
        client.itemsByIDsResult = .success([
            dtoSeason("se1", seriesID: "ser1"),
            dtoSeries("ser1"),
        ])
        let items = try await repo.continueWatching()
        guard case .episode(let ep) = items.first else {
            Issue.record("expected .episode")
            return
        }
        #expect(ep.seasonImageRef == nil)
        #expect(ep.seriesImageRef?.itemID.rawValue == "ser1")
        #expect(ep.seriesImageRef?.tag.rawValue == "series-poster")
        #expect(Set(client.itemsByIDsCalls.last ?? []) == Set(["se1", "ser1"]))
    }

    @Test("nextUp() returns Episode items")
    func nextUp() async throws {
        let (repo, client) = make()
        client.nextUpResult = .success([
            dtoEpisode("e1", seriesID: "ser1", seasonID: "se1"),
        ])
        client.itemsByIDsResult = .success([dtoSeason("se1", seriesID: "ser1", primaryTag: "season-folder-art")])
        let items = try await repo.nextUp()
        #expect(items.count == 1)
        guard case .episode(let ep) = items.first else {
            Issue.record("expected .episode")
            return
        }
        #expect(ep.seasonImageRef?.tag.rawValue == "season-folder-art")
        #expect(Set(client.itemsByIDsCalls.last ?? []) == Set(["se1", "ser1"]))
    }

    /// The enrichment fetch exists to fill MISSING parent art. A shelf of movies (or of episodes
    /// that already carry their season ref) must not pay a batch lookup at all.
    @Test("A shelf needing no parent art costs no batch lookup")
    func homeShelfWithoutMissingArtSkipsTheFetch() async throws {
        let (repo, client) = make()
        client.continueWatchingResult = .success([dtoMovie("m1")])

        let items = try await repo.continueWatching()

        #expect(items.count == 1)
        #expect(client.itemsByIDsCalls.isEmpty, "movies have no parent art to resolve")
    }

    /// Each repository call maps its transport failure into the domain error type, so no screen
    /// ever has to interpret a raw SDK error.
    @Test(
        "Every repository call maps a transport failure to AppError",
        arguments: [
            RepositoryCall.collections, .seasons, .episodes, .continueWatching, .nextUp, .search,
            .homeHeroFeed, .setFavorite, .setPlayed, .mediaSegments, .adjacentEpisodes,
        ]
    )
    func transportFailuresMapToAppError(call: RepositoryCall) async throws {
        let (repo, client) = make()
        let failure = URLError(.notConnectedToInternet)
        switch call {
        case .collections: client.collectionsResult = .failure(failure)
        case .seasons: client.seasonsResult = .failure(failure)
        case .episodes: client.episodesResult = .failure(failure)
        case .continueWatching: client.continueWatchingResult = .failure(failure)
        case .nextUp: client.nextUpResult = .failure(failure)
        case .search: client.searchResult = .failure(failure)
        case .homeHeroFeed: client.recentlyAddedResultsByTypes = [.movie: .failure(failure)]
        case .setFavorite: client.setFavoriteResult = .failure(failure)
        case .setPlayed: client.setPlayedResult = .failure(failure)
        case .mediaSegments: client.mediaSegmentsResult = .failure(failure)
        case .adjacentEpisodes: client.adjacentEpisodesResult = .failure(failure)
        }

        await #expect(throws: AppError.self) {
            switch call {
            case .collections: _ = try await repo.collections()
            case .seasons: _ = try await repo.seasons(of: ItemID(rawValue: "ser1"))
            case .episodes: _ = try await repo.episodes(of: ItemID(rawValue: "se1"))
            case .continueWatching: _ = try await repo.continueWatching()
            case .nextUp: _ = try await repo.nextUp()
            case .search: _ = try await repo.search("bad", scope: .all)
            case .homeHeroFeed: _ = try await repo.homeHeroFeed(limit: 12)
            case .setFavorite: _ = try await repo.setFavorite(itemID: ItemID(rawValue: "i1"), isFavorite: true)
            case .setPlayed: _ = try await repo.setPlayed(itemID: ItemID(rawValue: "i1"), isPlayed: true)
            case .mediaSegments: _ = try await repo.mediaSegments(for: ItemID(rawValue: "i1"))
            case .adjacentEpisodes:
                _ = try await repo.adjacentEpisodes(seriesID: ItemID(rawValue: "ser1"), episodeID: ItemID(rawValue: "e2"))
            }
        }
    }

    enum RepositoryCall: Sendable {
        case collections, seasons, episodes, continueWatching, nextUp, search
        case homeHeroFeed, setFavorite, setPlayed, mediaSegments, adjacentEpisodes
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

    @Test("search drops wrong-type DTOs the server leaks into a scoped result")
    func searchDropsWrongType() async throws {
        let (repo, client) = make()
        var box = BaseItemDto()
        box.id = "b1"; box.name = "Marvel Collection"; box.type = .boxSet
        // Server returns a BoxSet inside the movies-scoped /Items response.
        client.searchResultsByScope = [
            .movies: .success([dtoMovie("m1"), box]),
            .series: .success([]),
            .episodes: .success([]),
        ]
        let results = try await repo.search("marvel", scope: .all)
        // The BoxSet must be filtered out by the type guard — only the real
        // movie survives, so tapping a result never lands on a dead detail page.
        #expect(results.movies.count == 1)
        #expect(results.movies.first?.title == "Movie m1")
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
