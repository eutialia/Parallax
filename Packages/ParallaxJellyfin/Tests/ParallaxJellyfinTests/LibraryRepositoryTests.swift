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
        let filter = ItemFilter(watchState: .unplayed, favoritesOnly: true)
        let sort = ItemSort(field: .dateAdded, direction: .descending)
        _ = try await repo.items(
            in: CollectionID(rawValue: "coll-movies"),
            filter: filter,
            sort: sort,
            cursor: nil
        )
        #expect(client.itemsCalls.last?.filter == filter)
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
}
