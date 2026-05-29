import Foundation
import Testing
@testable import ParallaxJellyfin

@Suite("PlaybackInfoServiceStore — per-server memoization")
struct PlaybackInfoServiceStoreTests {
    private func session(id: String, token: String) -> Session {
        Session(
            persisted: PersistedSession(
                id: ServerID(rawValue: id),
                serverURL: URL(string: "https://j.example.com")!,
                serverName: "Home",
                user: UserSnapshot(id: "u-\(id)", name: "alice", serverLastUpdatedAt: nil)
            ),
            accessToken: token
        )
    }

    @Test("Same server + token returns the same service instance")
    func memoizedPerServer() async {
        let factory = FakeJellyfinPlaybackClientFactory()
        let store = PlaybackInfoServiceStore(clientFactory: factory)
        let s = session(id: "s1", token: "tok-1")
        let a = await store.service(for: s)
        let b = await store.service(for: s)
        #expect(a === b)
        #expect(factory.makeCalls == [ServerID(rawValue: "s1")])
    }

    @Test("A rotated token rebuilds the service with a fresh client")
    func rotatedTokenRebuilds() async {
        let factory = FakeJellyfinPlaybackClientFactory()
        let store = PlaybackInfoServiceStore(clientFactory: factory)
        let first = await store.service(for: session(id: "s1", token: "tok-1"))
        let second = await store.service(for: session(id: "s1", token: "tok-2"))
        #expect(first !== second)
        #expect(factory.makeCalls.count == 2)
    }

    @Test("Different servers get different services")
    func distinctServers() async {
        let factory = FakeJellyfinPlaybackClientFactory()
        let store = PlaybackInfoServiceStore(clientFactory: factory)
        let a = await store.service(for: session(id: "s1", token: "tok-1"))
        let b = await store.service(for: session(id: "s2", token: "tok-1"))
        #expect(a !== b)
    }
}
