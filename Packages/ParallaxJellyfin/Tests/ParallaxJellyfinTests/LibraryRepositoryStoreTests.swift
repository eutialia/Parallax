import Foundation
import Testing
import ParallaxCore
@testable import ParallaxJellyfin

@Suite("LibraryRepositoryStore")
struct LibraryRepositoryStoreTests {
    private func session(id: String, token: String) -> Session {
        Session(
            id: ServerID(rawValue: id),
            data: JellyfinServerData(
                serverURL: URL(string: "https://\(id).example.com")!,
                serverName: id,
                user: UserSnapshot(id: "u-\(id)", name: "alice", serverLastUpdatedAt: nil)
            ),
            accessToken: token
        )
    }

    @Test("Same server returns the same repo and builds the client once")
    func memoised() async {
        let factory = FakeJellyfinLibraryClientFactory()
        let store = LibraryRepositoryStore(clientFactory: factory)
        let s = session(id: "a", token: "tok-a")
        let r1 = await store.repository(for: s)
        let r2 = await store.repository(for: s)
        #expect(r1 === r2)
        #expect(factory.makeCalls == [ServerID(rawValue: "a")])
    }

    @Test("Different servers get distinct repos")
    func perServer() async {
        let factory = FakeJellyfinLibraryClientFactory()
        let store = LibraryRepositoryStore(clientFactory: factory)
        let r1 = await store.repository(for: session(id: "a", token: "tok-a"))
        let r2 = await store.repository(for: session(id: "b", token: "tok-b"))
        #expect(r1 !== r2)
        #expect(factory.makeCalls.count == 2)
    }

    @Test("Rotated token rebuilds the repo for the same server")
    func tokenRotation() async {
        let factory = FakeJellyfinLibraryClientFactory()
        let store = LibraryRepositoryStore(clientFactory: factory)
        let r1 = await store.repository(for: session(id: "a", token: "tok-old"))
        let r2 = await store.repository(for: session(id: "a", token: "tok-new"))
        #expect(r1 !== r2)
        #expect(factory.makeCalls.count == 2)
    }
}
