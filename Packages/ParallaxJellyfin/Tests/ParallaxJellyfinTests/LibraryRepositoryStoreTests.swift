import Foundation
import Testing
import ParallaxCore
@testable import ParallaxJellyfin

/// The three per-server stores share ONE contract — same server+token reuses the instance, a
/// different server gets its own, a rotated token rebuilds — so it is asserted once in
/// `verifyMemoization` and applied to each store. What differs per store is what a cache MISS
/// costs, which each suite adds on top.
@Suite("LibraryRepositoryStore")
struct LibraryRepositoryStoreTests {
    @Test("Repositories are memoized per server and rebuilt on a rotated token")
    func memoizationContract() async {
        let factory = FakeJellyfinLibraryClientFactory()
        let store = LibraryRepositoryStore(clientFactory: factory)
        await verifyMemoization { await store.repository(for: $0) }
    }

    /// The point of the cache: without it every screen's `.task` builds its own repo AND its own
    /// backing client, duplicating network calls for the same item.
    @Test("A cache hit costs no new client; a rotation costs exactly one")
    func clientConstructionFollowsTheCache() async {
        let factory = FakeJellyfinLibraryClientFactory()
        let store = LibraryRepositoryStore(clientFactory: factory)

        _ = await store.repository(for: JellyfinFixtures.session(id: "a", token: "tok-a"))
        _ = await store.repository(for: JellyfinFixtures.session(id: "a", token: "tok-a"))
        #expect(factory.makeCalls == [ServerID(rawValue: "a")])

        _ = await store.repository(for: JellyfinFixtures.session(id: "a", token: "tok-new"))
        #expect(factory.makeCalls == [ServerID(rawValue: "a"), ServerID(rawValue: "a")])
    }
}
