import Foundation
import Testing
import JellyfinAPI
import ParallaxCore
@testable import ParallaxJellyfin

@Suite("LibraryRepository — collections, items, detail")
struct LibraryRepositoryTests {
    private func make() -> (LibraryRepository, FakeJellyfinLibraryClient, Session) {
        let session = sampleSession()
        let client = FakeJellyfinLibraryClient()
        let repo = LibraryRepository(session: session, client: client)
        return (repo, client, session)
    }

    private func sampleSession() -> Session {
        let persisted = PersistedSession(
            id: ServerID(rawValue: "s1"),
            serverURL: URL(string: "https://j.example.com")!,
            serverName: "Home",
            user: UserSnapshot(id: "u1", name: "alice", serverLastUpdatedAt: nil)
        )
        return Session(persisted: persisted, accessToken: "tok-1")
    }

    private func moviesCollectionDto() -> BaseItemDto {
        var dto = BaseItemDto()
        dto.id = "coll-movies"
        dto.name = "Movies"
        dto.collectionType = .movies
        dto.imageTags = ["Primary": "p-tag"]
        return dto
    }

    private func sampleMovieDto(id: String) -> BaseItemDto {
        var dto = BaseItemDto()
        dto.id = id
        dto.name = "Movie \(id)"
        dto.type = .movie
        return dto
    }

    private func sampleEpisodeDto(id: String = "ep-1", seriesID: String = "ser-1", seasonID: String = "sea-1") -> BaseItemDto {
        var dto = BaseItemDto()
        dto.id = id
        dto.name = "Episode \(id)"
        dto.type = .episode
        dto.seriesID = seriesID
        dto.seasonID = seasonID
        return dto
    }

    @Test("collections() returns translated MediaCollections")
    func collections() async throws {
        let (repo, client, _) = make()
        client.collectionsResult = .success([moviesCollectionDto()])
        let result = try await repo.collections()
        #expect(result.count == 1)
        #expect(result.first?.name == "Movies")
        #expect(result.first?.collectionType == .movies)
        #expect(client.collectionsCallCount == 1)
    }

    @Test("collections() maps client errors to AppError")
    func collectionsErrorMaps() async throws {
        let (repo, client, _) = make()
        client.collectionsResult = .failure(URLError(.notConnectedToInternet))
        await #expect(throws: AppError.self) {
            _ = try await repo.collections()
        }
    }

    @Test("items() returns Page with nextCursor when more results available")
    func itemsPagination() async throws {
        let (repo, client, _) = make()
        client.itemsResult = .success((items: (0..<50).map { sampleMovieDto(id: "m\($0)") }, total: 120))

        let page1 = try await repo.items(
            in: CollectionID(rawValue: "coll-movies"),
            filter: ItemFilter(),
            sort: .defaultForLibrary,
            cursor: nil
        )
        #expect(page1.items.count == 50)
        #expect(page1.total == 120)
        #expect(page1.nextCursor != nil)

        // Second page: client returns next 50; cursor still valid.
        client.itemsResult = .success((items: (50..<100).map { sampleMovieDto(id: "m\($0)") }, total: 120))
        let page2 = try await repo.items(
            in: CollectionID(rawValue: "coll-movies"),
            filter: ItemFilter(),
            sort: .defaultForLibrary,
            cursor: page1.nextCursor
        )
        #expect(page2.items.count == 50)
        #expect(page2.nextCursor != nil)

        // Third page: only 20 items remain; nextCursor goes nil.
        client.itemsResult = .success((items: (100..<120).map { sampleMovieDto(id: "m\($0)") }, total: 120))
        let page3 = try await repo.items(
            in: CollectionID(rawValue: "coll-movies"),
            filter: ItemFilter(),
            sort: .defaultForLibrary,
            cursor: page2.nextCursor
        )
        #expect(page3.items.count == 20)
        #expect(page3.nextCursor == nil)
    }

    @Test("items() forwards filter and sort to the client unchanged")
    func itemsForwardsParams() async throws {
        let (repo, client, _) = make()
        client.itemsResult = .success(([], 0))
        let filter = ItemFilter(watchState: .unplayed, favoritesOnly: true, genres: ["Action"])
        let sort = ItemSort(field: .dateAdded, direction: .descending)
        _ = try await repo.items(
            in: CollectionID(rawValue: "coll-movies"),
            filter: filter,
            sort: sort,
            cursor: nil
        )
        #expect(client.itemsCalls.last?.filter == filter)
        #expect(client.itemsCalls.last?.filter.genres == ["Action"])
        #expect(client.itemsCalls.last?.sort == sort)
        #expect(client.itemsCalls.last?.parentID == "coll-movies")
        #expect(client.itemsCalls.last?.startIndex == 0)
        #expect(client.itemsCalls.last?.limit == 50)
    }

    @Test("detail() returns the right ItemDetail case based on DTO type")
    func detail() async throws {
        let (repo, client, _) = make()
        var movieDto = sampleMovieDto(id: "m1")
        movieDto.taglines = ["A line"]
        client.detailResult = .success(movieDto)

        let detail = try await repo.detail(for: ItemID(rawValue: "m1"))
        guard case .movie(let md) = detail else {
            Issue.record("expected .movie, got \(detail)")
            return
        }
        #expect(md.movie.title == "Movie m1")
        #expect(md.tagline == "A line")
    }

    @Test("detail() throws when the DTO can't be translated")
    func detailMissingFields() async throws {
        let (repo, client, _) = make()
        var bad = BaseItemDto()
        bad.id = nil
        client.detailResult = .success(bad)
        await #expect(throws: AppError.self) {
            _ = try await repo.detail(for: ItemID(rawValue: "missing"))
        }
    }

    @Test("homeHeroFeed fetches series metadata and builds entries")
    func homeHeroFeed() async throws {
        let (repo, client, _) = make()
        let epDate = Date(timeIntervalSince1970: 5_000_000)
        var epDto = sampleEpisodeDto(id: "e2", seriesID: "ser-1", seasonID: "sea-1")
        epDto.dateCreated = epDate
        epDto.parentIndexNumber = 1
        epDto.indexNumber = 2
        client.recentlyAddedResult = .success([epDto])

        var seriesDto = BaseItemDto()
        seriesDto.id = "ser-1"
        seriesDto.name = "Show"
        seriesDto.type = .series
        seriesDto.dateCreated = Date(timeIntervalSince1970: 1_000_000)
        client.itemsByIDsResult = .success([seriesDto])

        let feed = try await repo.homeHeroFeed(limit: 12)
        #expect(feed.count == 1)
        #expect(feed[0].eyebrow == .newEpisodeAvailable)
        #expect(feed[0].presentation.id == ItemID(rawValue: "ser-1"))
        #expect(feed[0].playTarget.id == ItemID(rawValue: "e2"))
        #expect(client.itemsByIDsCalls.last == ["ser-1"])
    }
}

@Suite("LibraryRepository — setFavorite, setPlayed, resumeEpisode, genres")
struct LibraryRepositoryUserActionTests {
    private func make() -> (LibraryRepository, FakeJellyfinLibraryClient) {
        let persisted = PersistedSession(
            id: ServerID(rawValue: "s1"),
            serverURL: URL(string: "https://j.example.com")!,
            serverName: "Home",
            user: UserSnapshot(id: "u1", name: "alice", serverLastUpdatedAt: nil)
        )
        let session = Session(persisted: persisted, accessToken: "tok-1")
        let client = FakeJellyfinLibraryClient()
        let repo = LibraryRepository(session: session, client: client)
        return (repo, client)
    }

    private func sampleEpisodeDto(id: String = "ep-1", seriesID: String = "ser-1", seasonID: String = "sea-1") -> BaseItemDto {
        var dto = BaseItemDto()
        dto.id = id
        dto.name = "Episode \(id)"
        dto.type = .episode
        dto.seriesID = seriesID
        dto.seasonID = seasonID
        return dto
    }

    private func sampleMovieDto(id: String) -> BaseItemDto {
        var dto = BaseItemDto()
        dto.id = id
        dto.name = "Movie \(id)"
        dto.type = .movie
        return dto
    }

    @Test("setFavorite(true) forwards itemID and flag to client")
    func setFavoriteTrue() async throws {
        let (repo, client) = make()
        client.setFavoriteResult = .success(
            UserItemData(played: false, playbackPositionTicks: 0, playCount: 0, isFavorite: true)
        )
        let userData = try await repo.setFavorite(itemID: ItemID(rawValue: "item-42"), isFavorite: true)
        #expect(client.setFavoriteCalls.count == 1)
        #expect(client.setFavoriteCalls.last?.itemID == "item-42")
        #expect(client.setFavoriteCalls.last?.isFavorite == true)
        #expect(userData.isFavorite == true)
    }

    @Test("setFavorite propagates a client failure (so the VM's optimistic revert fires)")
    func setFavoritePropagatesError() async throws {
        let (repo, client) = make()
        client.setFavoriteResult = .failure(FakeJellyfinLibraryClient.FakeError.notConfigured)
        await #expect(throws: (any Error).self) {
            try await repo.setFavorite(itemID: ItemID(rawValue: "item-1"), isFavorite: true)
        }
    }

    @Test("setFavorite(false) forwards itemID and flag to client")
    func setFavoriteFalse() async throws {
        let (repo, client) = make()
        try await repo.setFavorite(itemID: ItemID(rawValue: "item-99"), isFavorite: false)
        #expect(client.setFavoriteCalls.last?.itemID == "item-99")
        #expect(client.setFavoriteCalls.last?.isFavorite == false)
    }

    @Test("setPlayed(true) forwards itemID and flag to client")
    func setPlayedTrue() async throws {
        let (repo, client) = make()
        try await repo.setPlayed(itemID: ItemID(rawValue: "item-7"), isPlayed: true)
        #expect(client.setPlayedCalls.count == 1)
        #expect(client.setPlayedCalls.last?.itemID == "item-7")
        #expect(client.setPlayedCalls.last?.isPlayed == true)
    }

    @Test("setPlayed(false) forwards itemID and flag to client")
    func setPlayedFalse() async throws {
        let (repo, client) = make()
        try await repo.setPlayed(itemID: ItemID(rawValue: "item-8"), isPlayed: false)
        #expect(client.setPlayedCalls.last?.itemID == "item-8")
        #expect(client.setPlayedCalls.last?.isPlayed == false)
    }

    @Test("resumeEpisode maps a BaseItemDto into an Episode")
    func resumeEpisodeMapsDto() async throws {
        let (repo, client) = make()
        client.seriesNextUpResult = .success(sampleEpisodeDto(id: "ep-5", seriesID: "ser-2", seasonID: "sea-3"))
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

    @Test("genres forwards parentID and returns client list")
    func genresForwards() async throws {
        let (repo, client) = make()
        client.genresResult = .success(["Action", "Drama"])
        let result = try await repo.genres(in: CollectionID(rawValue: "coll-1"))
        #expect(client.genresCalls == ["coll-1"])
        #expect(result == ["Action", "Drama"])
    }

    @Test("genres returns empty when client yields empty")
    func genresEmpty() async throws {
        let (repo, client) = make()
        client.genresResult = .success([])
        let result = try await repo.genres(in: CollectionID(rawValue: "coll-2"))
        #expect(result.isEmpty)
    }
}
