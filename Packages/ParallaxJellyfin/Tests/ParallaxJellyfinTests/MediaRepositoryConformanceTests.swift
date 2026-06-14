import Foundation
import Testing
import ParallaxCore
@testable import ParallaxJellyfin

@Suite("MediaRepository conformance")
struct MediaRepositoryConformanceTests {
    private func makeRepo() -> (LibraryRepository, FakeJellyfinLibraryClient) {
        let client = FakeJellyfinLibraryClient()
        let data = JellyfinServerData(
            serverURL: URL(string: "https://example.test")!,
            serverName: "Test",
            user: UserSnapshot(id: "u1", name: "alice", serverLastUpdatedAt: nil)
        )
        let session = Session(id: ServerID(rawValue: "s1"), data: data, accessToken: "token")
        return (LibraryRepository(session: session, client: client), client)
    }

    @Test("LibraryRepository is usable as any MediaRepository")
    func usableAsExistential() async throws {
        let (concrete, client) = makeRepo()
        client.collectionsResult = .success([])
        client.itemsResult = .success(([], 0))
        client.genresResult = .success(["Action"])
        let repo: any MediaRepository = concrete

        // Every protocol requirement must route through the existential, not just
        // collections() — otherwise a signature/behaviour drift on items()/genres()
        // would slip past this conformance check.
        let collections = try await repo.collections()
        #expect(collections.isEmpty)

        let page = try await repo.items(in: .favorites, filter: ItemFilter(), sort: .defaultForLibrary, cursor: nil)
        #expect(page.items.isEmpty)

        let genres = try await repo.genres(in: .collection(CollectionID(rawValue: "coll-1")))
        #expect(genres == ["Action"])
    }
}
