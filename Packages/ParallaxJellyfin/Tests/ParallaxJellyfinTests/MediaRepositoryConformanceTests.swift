import Foundation
import Testing
import ParallaxCore
@testable import ParallaxJellyfin

/// `MediaRepository` is the seam the browse UI is written against, so Jellyfin and (later) SMB can
/// back the same screens. This checks that the Jellyfin implementation satisfies it AND that each
/// requirement still does its translation work when called through the existential — a signature
/// drift that made a call route to a different overload would otherwise compile fine.
@Suite("MediaRepository conformance")
struct MediaRepositoryConformanceTests {
    @Test("Every MediaRepository requirement translates correctly through the existential")
    func usableAsExistential() async throws {
        let client = FakeJellyfinLibraryClient()
        let repo: any MediaRepository = LibraryRepository(session: JellyfinFixtures.session(), client: client)

        client.collectionsResult = .success([JellyfinFixtures.collectionDto(id: "coll-1", name: "Movies")])
        client.itemsResult = .success((items: [JellyfinFixtures.movieDto(id: "m1")], total: 1))
        client.genresResult = .success(["Action"])

        // A DTO in, a domain model out — proving translation happened, not that a stub echoed.
        let collections = try await repo.collections()
        #expect(collections.map(\.id) == [CollectionID(rawValue: "coll-1")])
        #expect(collections.first?.collectionType == .movies)

        let page = try await repo.items(in: .favorites, filter: ItemFilter(), sort: .defaultForLibrary, cursor: nil)
        #expect(page.items.map(\.id) == [ItemID(rawValue: "m1")])
        #expect(page.nextCursor == nil, "a page shorter than `total` allows ends the sequence")
        #expect(client.itemsCalls.last?.scope == .favorites, "the scope reached the client through the existential")

        // Genres pass through untranslated, but the SCOPE must still be forwarded.
        let genres = try await repo.genres(in: .collection(CollectionID(rawValue: "coll-1")))
        #expect(genres == ["Action"])
        #expect(client.genresCalls == [.collection(CollectionID(rawValue: "coll-1"))])
    }
}
