import Foundation
import Testing
import JellyfinAPI
import ParallaxCore
@testable import ParallaxJellyfin

@Suite("LibraryRepository — collections, items, detail")
struct LibraryRepositoryTests {
    private func make() -> (LibraryRepository, FakeJellyfinLibraryClient) {
        let client = FakeJellyfinLibraryClient()
        return (LibraryRepository(session: JellyfinFixtures.session(), client: client), client)
    }

    private let moviesLibrary = LibraryScope.collection(CollectionID(rawValue: "coll-movies"))

    @Test("collections() returns translated MediaCollections")
    func collections() async throws {
        let (repo, client) = make()
        client.collectionsResult = .success([JellyfinFixtures.collectionDto()])
        let result = try await repo.collections()
        #expect(result.count == 1)
        #expect(result.first?.name == "Movies")
        #expect(result.first?.collectionType == .movies)
        #expect(client.collectionsCallCount == 1)
    }

    @Test("collections() maps client errors to AppError")
    func collectionsErrorMaps() async throws {
        let (repo, client) = make()
        client.collectionsResult = .failure(URLError(.notConnectedToInternet))
        await #expect(throws: AppError.self) {
            _ = try await repo.collections()
        }
    }

    @Test("items() returns Page with nextCursor when more results available")
    func itemsPagination() async throws {
        let (repo, client) = make()
        let pageSize = LibraryRepository.pageSize
        client.itemsResult = .success((items: (0..<pageSize).map { JellyfinFixtures.movieDto(id: "m\($0)") }, total: 120))

        let page1 = try await repo.items(in: moviesLibrary, filter: ItemFilter(), sort: .defaultForLibrary, cursor: nil)
        #expect(page1.items.count == pageSize)
        #expect(page1.total == 120)
        #expect(page1.nextCursor == .startIndex(pageSize))

        // Second page: the client returns the next window; the cursor still advances.
        client.itemsResult = .success((items: (pageSize..<(pageSize * 2)).map { JellyfinFixtures.movieDto(id: "m\($0)") }, total: 120))
        let page2 = try await repo.items(in: moviesLibrary, filter: ItemFilter(), sort: .defaultForLibrary, cursor: page1.nextCursor)
        #expect(page2.items.count == pageSize)
        #expect(page2.nextCursor == .startIndex(pageSize * 2))

        // Final partial page: the window closes exactly on `total`, so the cursor goes nil.
        let remaining = 120 - pageSize * 2
        client.itemsResult = .success((items: (0..<remaining).map { JellyfinFixtures.movieDto(id: "tail\($0)") }, total: 120))
        let page3 = try await repo.items(in: moviesLibrary, filter: ItemFilter(), sort: .defaultForLibrary, cursor: page2.nextCursor)
        #expect(page3.items.count == remaining)
        #expect(page3.nextCursor == nil)
    }

    @Test("items() stops paginating on an empty mid-sequence page (no infinite re-fetch)")
    func itemsEmptyPageEndsPagination() async throws {
        let (repo, client) = make()
        let pageSize = LibraryRepository.pageSize
        client.itemsResult = .success((items: (0..<pageSize).map { JellyfinFixtures.movieDto(id: "m\($0)") }, total: 120))
        let page1 = try await repo.items(in: moviesLibrary, filter: ItemFilter(), sort: .defaultForLibrary, cursor: nil)
        #expect(page1.nextCursor != nil)

        // The second page comes back empty even though `total` still says 120 (server deletions /
        // over-reported total). The cursor must terminate, not repeat the same startIndex forever.
        client.itemsResult = .success((items: [], total: 120))
        let page2 = try await repo.items(in: moviesLibrary, filter: ItemFilter(), sort: .defaultForLibrary, cursor: page1.nextCursor)
        #expect(page2.items.isEmpty)
        #expect(page2.nextCursor == nil)
    }

    @Test("items() forwards filter and sort to the client unchanged")
    func itemsForwardsParams() async throws {
        let (repo, client) = make()
        let filter = ItemFilter(genres: ["Action"])
        let sort = ItemSort(field: .dateAdded, direction: .descending)
        _ = try await repo.items(in: moviesLibrary, filter: filter, sort: sort, cursor: nil)
        #expect(client.itemsCalls.last?.filter == filter)
        #expect(client.itemsCalls.last?.sort == sort)
        #expect(client.itemsCalls.last?.scope == moviesLibrary)
        #expect(client.itemsCalls.last?.startIndex == 0)
        #expect(client.itemsCalls.last?.limit == LibraryRepository.pageSize)
    }

    @Test("items() forwards the favorites scope to the client")
    func itemsFavoritesScope() async throws {
        let (repo, client) = make()
        _ = try await repo.items(in: .favorites, filter: ItemFilter(), sort: .defaultForLibrary, cursor: nil)
        #expect(client.itemsCalls.last?.scope == .favorites)
    }

    /// Only movie/series/episode DTOs have a detail destination; anything else the server folds
    /// into a library page (a BoxSet, a playlist folder) must be dropped rather than rendered as
    /// a tile that leads nowhere.
    @Test("items() drops DTOs of a kind the app has no destination for")
    func itemsDropUnsupportedKinds() async throws {
        let (repo, client) = make()
        var boxSet = BaseItemDto()
        boxSet.id = "b1"
        boxSet.name = "Marvel Collection"
        boxSet.type = .boxSet
        client.itemsResult = .success((items: [JellyfinFixtures.movieDto(id: "m1"), boxSet], total: 2))

        let page = try await repo.items(in: moviesLibrary, filter: ItemFilter(), sort: .defaultForLibrary, cursor: nil)

        #expect(page.items.map(\.id) == [ItemID(rawValue: "m1")])
        // `total` stays the server's count — the cursor arithmetic is the server's, not ours.
        #expect(page.total == 2)
    }

    @Test("detail() returns the right ItemDetail case based on DTO type")
    func detail() async throws {
        let (repo, client) = make()
        var movieDto = JellyfinFixtures.movieDto(id: "m1")
        movieDto.taglines = ["A line"]
        client.detailResult = .success(movieDto)

        let detail = try await repo.detail(for: ItemID(rawValue: "m1"))
        guard case .movie(let md) = detail else {
            Issue.record("expected .movie, got \(detail)")
            return
        }
        #expect(client.detailCalls == ["m1"])
        #expect(md.movie.title == "Movie m1")
        #expect(md.tagline == "A line")
    }

    @Test("detail() throws when the DTO can't be translated")
    func detailMissingFields() async throws {
        let (repo, client) = make()
        var bad = BaseItemDto()
        bad.id = nil
        client.detailResult = .success(bad)
        await #expect(throws: AppError.self) {
            _ = try await repo.detail(for: ItemID(rawValue: "missing"))
        }
    }

    @Test("homeHeroFeed fetches series metadata and builds entries")
    func homeHeroFeed() async throws {
        let (repo, client) = make()
        let epDto = JellyfinFixtures.episodeDto(
            id: "e2",
            indexNumber: 2,
            parentIndexNumber: 1,
            dateCreated: Date(timeIntervalSince1970: 5_000_000)
        )
        client.recentlyAddedResultsByTypes = [.episode: .success([epDto])]
        client.itemsByIDsResult = .success([
            JellyfinFixtures.seriesDto(id: "ser-1", name: "Show", dateCreated: Date(timeIntervalSince1970: 1_000_000)),
        ])

        let feed = try await repo.homeHeroFeed(limit: 12)
        #expect(feed.count == 1)
        #expect(feed[0].eyebrow == .newEpisodeAvailable)
        #expect(feed[0].presentation.id == ItemID(rawValue: "ser-1"))
        #expect(feed[0].playTarget.id == ItemID(rawValue: "e2"))
        #expect(client.itemsByIDsCalls.last == ["ser-1"])
        #expect(client.recentlyAddedCalls.count == 2)
        let movieCall = client.recentlyAddedCalls.first { $0.types == [.movie] }
        let episodeCall = client.recentlyAddedCalls.first { $0.types == [.episode] }
        #expect(movieCall?.limit == 12)
        // Episodes are over-fetched so a bulk import can't crowd the carousel out post-dedupe;
        // the size of that over-fetch is the builder's to define, not this test's.
        #expect(episodeCall?.limit == HomeHeroFeedBuilder.episodeLatestFetchLimit(presentationLimit: 12))
    }

    @Test("homeHeroFeed retains series logo from batch metadata")
    func homeHeroFeedSeriesLogo() async throws {
        let (repo, client) = make()
        client.recentlyAddedResultsByTypes = [.episode: .success([JellyfinFixtures.episodeDto(id: "e1")])]
        client.itemsByIDsResult = .success([
            JellyfinFixtures.seriesDto(id: "ser-1", name: "Show", imageTags: ["Logo": "logo-tag"]),
        ])

        let feed = try await repo.homeHeroFeed(limit: 12)
        #expect(feed.count == 1)
        guard case .series(let series) = feed[0].presentation else {
            Issue.record("Expected series presentation")
            return
        }
        #expect(series.imageRef(.logo)?.tag.rawValue == "logo-tag")
    }

    /// A newly-added series' hero should open the show from the start, but a bulk-import batch
    /// rarely contains S1E1 — so the repository asks the server for the series' resume point and
    /// hands it to the builder as the fallback play target.
    @Test("homeHeroFeed asks the server for a start episode when a newly added series' batch lacks S1E1")
    func homeHeroFeedFetchesFirstEpisodeFallback() async throws {
        let (repo, client) = make()
        let importedAt = Date(timeIntervalSince1970: 5_000_000)
        // Three episodes landing together inside the import window = a bulk import.
        client.recentlyAddedResultsByTypes = [
            .episode: .success((4...6).map { (index: Int) in
                JellyfinFixtures.episodeDto(id: "e\(index)", indexNumber: index, parentIndexNumber: 1, dateCreated: importedAt)
            }),
        ]
        client.itemsByIDsResult = .success([
            JellyfinFixtures.seriesDto(id: "ser-1", name: "Show", dateCreated: importedAt),
        ])
        client.seriesNextUpResult = .success(
            JellyfinFixtures.episodeDto(id: "e1", indexNumber: 1, parentIndexNumber: 1)
        )

        let feed = try await repo.homeHeroFeed(limit: 12)

        #expect(client.seriesNextUpCalls == ["ser-1"])
        #expect(feed.first?.eyebrow == .newlyAdded)
        // The batch's earliest episode still wins when present; the fallback only fills the gap
        // when the batch has none at all.
        #expect(feed.first?.playTarget.id == ItemID(rawValue: "e4"))
    }

    /// A batch that already contains S1E1 needs no extra round-trip.
    @Test("homeHeroFeed skips the fallback fetch when S1E1 is already in the batch")
    func homeHeroFeedSkipsFallbackWhenS1E1Present() async throws {
        let (repo, client) = make()
        let importedAt = Date(timeIntervalSince1970: 5_000_000)
        client.recentlyAddedResultsByTypes = [
            .episode: .success((1...3).map { (index: Int) in
                JellyfinFixtures.episodeDto(id: "e\(index)", indexNumber: index, parentIndexNumber: 1, dateCreated: importedAt)
            }),
        ]
        client.itemsByIDsResult = .success([
            JellyfinFixtures.seriesDto(id: "ser-1", name: "Show", dateCreated: importedAt),
        ])

        let feed = try await repo.homeHeroFeed(limit: 12)

        #expect(client.seriesNextUpCalls.isEmpty)
        #expect(feed.first?.playTarget.id == ItemID(rawValue: "e1"))
    }

    @Test("homeHeroFeed maps a transport failure to AppError")
    func homeHeroFeedErrorMaps() async throws {
        let (repo, client) = make()
        client.recentlyAddedResultsByTypes = [.movie: .failure(URLError(.timedOut))]
        await #expect(throws: AppError.self) {
            _ = try await repo.homeHeroFeed(limit: 12)
        }
    }
}

@Suite("LibraryRepository — setFavorite, setPlayed, resumeEpisode, genres, segments")
struct LibraryRepositoryUserActionTests {
    private func make() -> (LibraryRepository, FakeJellyfinLibraryClient) {
        let client = FakeJellyfinLibraryClient()
        return (LibraryRepository(session: JellyfinFixtures.session(), client: client), client)
    }

    @Test("setFavorite forwards the flag and returns the server's user data", arguments: [true, false])
    func setFavoriteForwardsFlag(isFavorite: Bool) async throws {
        let (repo, client) = make()
        // Stubbed explicitly: the fake no longer folds the passed flag into its answer, so this
        // asserts the repository returns what the SERVER said.
        client.setFavoriteResult = .success(
            UserItemData(played: true, playbackPositionTicks: 42, playCount: 3, isFavorite: isFavorite)
        )

        let userData = try await repo.setFavorite(itemID: ItemID(rawValue: "item-42"), isFavorite: isFavorite)

        #expect(client.setFavoriteCalls.count == 1)
        #expect(client.setFavoriteCalls.last?.itemID == "item-42")
        #expect(client.setFavoriteCalls.last?.isFavorite == isFavorite)
        #expect(userData.isFavorite == isFavorite)
        #expect(userData.playCount == 3)
    }

    @Test("setFavorite propagates a client failure (so the VM's optimistic revert fires)")
    func setFavoritePropagatesError() async throws {
        let (repo, client) = make()
        client.setFavoriteResult = .failure(FakeJellyfinLibraryClient.FakeError.notConfigured)
        await #expect(throws: AppError.self) {
            try await repo.setFavorite(itemID: ItemID(rawValue: "item-1"), isFavorite: true)
        }
    }

    @Test("setPlayed forwards the flag and returns the server's user data", arguments: [true, false])
    func setPlayedForwardsFlag(isPlayed: Bool) async throws {
        let (repo, client) = make()
        client.setPlayedResult = .success(
            UserItemData(played: isPlayed, playbackPositionTicks: 0, playCount: isPlayed ? 1 : 0, isFavorite: true)
        )

        let userData = try await repo.setPlayed(itemID: ItemID(rawValue: "item-7"), isPlayed: isPlayed)

        #expect(client.setPlayedCalls.count == 1)
        #expect(client.setPlayedCalls.last?.itemID == "item-7")
        #expect(client.setPlayedCalls.last?.isPlayed == isPlayed)
        #expect(userData.played == isPlayed)
    }

    @Test("setPlayed propagates a client failure")
    func setPlayedPropagatesError() async throws {
        let (repo, client) = make()
        client.setPlayedResult = .failure(URLError(.notConnectedToInternet))
        await #expect(throws: AppError.self) {
            try await repo.setPlayed(itemID: ItemID(rawValue: "item-7"), isPlayed: true)
        }
    }

    @Test("resumeEpisode maps a BaseItemDto into an Episode")
    func resumeEpisodeMapsDto() async throws {
        let (repo, client) = make()
        client.seriesNextUpResult = .success(
            JellyfinFixtures.episodeDto(id: "ep-5", seriesID: "ser-2", seasonID: "sea-3")
        )
        let episode = try await repo.resumeEpisode(forSeries: ItemID(rawValue: "ser-2"))
        #expect(client.seriesNextUpCalls == ["ser-2"])
        #expect(episode?.id == ItemID(rawValue: "ep-5"))
        #expect(episode?.seriesID == ItemID(rawValue: "ser-2"))
        #expect(episode?.name == "Episode ep-5")
    }

    @Test("resumeEpisode returns nil when client yields nil")
    func resumeEpisodeNil() async throws {
        let (repo, client) = make()
        client.seriesNextUpResult = .success(nil)
        let episode = try await repo.resumeEpisode(forSeries: ItemID(rawValue: "ser-1"))
        #expect(episode == nil)
        #expect(client.seriesNextUpCalls == ["ser-1"])
    }

    @Test("genres forwards the scope and returns client list")
    func genresForwards() async throws {
        let (repo, client) = make()
        client.genresResult = .success(["Action", "Drama"])
        let result = try await repo.genres(in: .collection(CollectionID(rawValue: "coll-1")))
        #expect(client.genresCalls == [.collection(CollectionID(rawValue: "coll-1"))])
        #expect(result == ["Action", "Drama"])
    }

    /// Segments drive the Skip Intro / Next Episode affordances; an unusable span must be dropped
    /// here rather than reaching the player as a marker the playhead can never fall inside.
    @Test("mediaSegments forwards the item id and drops unusable spans")
    func mediaSegments() async throws {
        let (repo, client) = make()
        var intro = MediaSegmentDto()
        intro.id = "seg-1"
        intro.type = .intro
        intro.startTicks = 0
        intro.endTicks = 300_000_000
        var broken = MediaSegmentDto()
        broken.id = "seg-2"
        broken.type = .outro
        broken.startTicks = 500_000_000
        broken.endTicks = nil
        client.mediaSegmentsResult = .success([intro, broken])

        let segments = try await repo.mediaSegments(for: ItemID(rawValue: "item-1"))

        #expect(client.mediaSegmentsCalls == ["item-1"])
        #expect(segments.map(\.kind) == [.intro])
    }

    @Test("mediaSegments maps a transport failure to AppError")
    func mediaSegmentsErrorMaps() async throws {
        let (repo, client) = make()
        client.mediaSegmentsResult = .failure(URLError(.timedOut))
        await #expect(throws: AppError.self) {
            _ = try await repo.mediaSegments(for: ItemID(rawValue: "item-1"))
        }
    }

    /// The window is [previous, self, next] in airing order, so neighbours are positional — which
    /// is what lets a season finale hand off to the next season's premiere.
    @Test("adjacentEpisodes resolves neighbours out of the server's window")
    func adjacentEpisodes() async throws {
        let (repo, client) = make()
        client.adjacentEpisodesResult = .success([
            JellyfinFixtures.episodeDto(id: "e1", indexNumber: 1),
            JellyfinFixtures.episodeDto(id: "e2", indexNumber: 2),
            JellyfinFixtures.episodeDto(id: "e3", indexNumber: 3),
        ])

        let adjacent = try await repo.adjacentEpisodes(
            seriesID: ItemID(rawValue: "ser-1"),
            episodeID: ItemID(rawValue: "e2")
        )

        #expect(client.adjacentEpisodesCalls.map(\.seriesID) == ["ser-1"])
        #expect(client.adjacentEpisodesCalls.map(\.episodeID) == ["e2"])
        #expect(adjacent.previous?.id == ItemID(rawValue: "e1"))
        #expect(adjacent.next?.id == ItemID(rawValue: "e3"))
    }

    @Test("adjacentEpisodes maps a transport failure to AppError")
    func adjacentEpisodesErrorMaps() async throws {
        let (repo, client) = make()
        client.adjacentEpisodesResult = .failure(URLError(.timedOut))
        await #expect(throws: AppError.self) {
            _ = try await repo.adjacentEpisodes(
                seriesID: ItemID(rawValue: "ser-1"),
                episodeID: ItemID(rawValue: "e2")
            )
        }
    }
}
