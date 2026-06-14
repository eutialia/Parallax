import Foundation
import Testing
import ParallaxCore
@testable import ParallaxJellyfin

@Suite("MediaRepository conformance")
struct MediaRepositoryConformanceTests {
    private func makeRepo() -> (LibraryRepository, FakeJellyfinLibraryClient) {
        let client = FakeJellyfinLibraryClient()
        let persisted = PersistedSession(
            id: ServerID(rawValue: "s1"),
            serverURL: URL(string: "https://example.test")!,
            serverName: "Test",
            user: UserSnapshot(id: "u1", name: "alice", serverLastUpdatedAt: nil)
        )
        let session = Session(persisted: persisted, accessToken: "token")
        return (LibraryRepository(session: session, client: client), client)
    }

    @Test("LibraryRepository is usable as any MediaRepository")
    func usableAsExistential() async throws {
        let (concrete, client) = makeRepo()
        client.collectionsResult = .success([])
        let repo: any MediaRepository = concrete
        let collections = try await repo.collections()
        #expect(collections.isEmpty)
    }
}
