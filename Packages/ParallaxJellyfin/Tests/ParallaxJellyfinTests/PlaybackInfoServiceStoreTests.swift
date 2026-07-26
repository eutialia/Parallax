import Foundation
import Testing
@testable import ParallaxJellyfin

@Suite("PlaybackInfoServiceStore — per-server memoization")
struct PlaybackInfoServiceStoreTests {
    @Test("Playback services are memoized per server and rebuilt on a rotated token")
    func memoizationContract() async {
        let factory = FakeJellyfinPlaybackClientFactory()
        let store = PlaybackInfoServiceStore(clientFactory: factory)
        await verifyMemoization { await store.service(for: $0) }
    }

    /// A rotated token must reach the network: a reused client would keep sending the dead one and
    /// every playback start would 401.
    @Test("Only a cache miss builds a client")
    func clientConstructionFollowsTheCache() async {
        let factory = FakeJellyfinPlaybackClientFactory()
        let store = PlaybackInfoServiceStore(clientFactory: factory)

        _ = await store.service(for: JellyfinFixtures.session(id: "s1", token: "tok-1"))
        _ = await store.service(for: JellyfinFixtures.session(id: "s1", token: "tok-1"))
        #expect(factory.makeCalls == [ServerID(rawValue: "s1")])

        _ = await store.service(for: JellyfinFixtures.session(id: "s1", token: "tok-2"))
        _ = await store.service(for: JellyfinFixtures.session(id: "s2", token: "tok-1"))
        #expect(factory.makeCalls.count == 3)
    }
}
