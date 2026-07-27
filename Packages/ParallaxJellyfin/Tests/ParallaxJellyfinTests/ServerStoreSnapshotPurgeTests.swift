import Foundation
import Testing
import ParallaxCore
import ParallaxCoreTestSupport
@testable import ParallaxJellyfin

/// A server's cached payloads have exactly the lifetime of the server. `ServerStore` is where a
/// server stops existing — deliberately (`remove`) or because its token died (`invalidateSession`)
/// — so it is where the snapshots go too. Leaving them behind would hydrate the next launch with
/// shelves and libraries belonging to a server that is no longer signed in.
@Suite("ServerStore snapshot purge")
struct ServerStoreSnapshotPurgeTests {
    private func withHarness(
        _ label: String,
        _ body: (ServerStore, SnapshotStore) async throws -> Void
    ) async throws {
        let container = URL.temporaryDirectory.appending(
            path: "server-store-snapshots-\(UUID().uuidString)", directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: container) }
        let harness = JellyfinFixtures.serverStore(label)
        let snapshots = SnapshotStore(container: container)
        let store = ServerStore(settings: harness.settings, keychain: harness.keychain, snapshots: snapshots)
        try await body(store, snapshots)
    }

    private func seed(_ snapshots: SnapshotStore, serverID: String) async {
        await snapshots.setLibraries([LibraryFixtures.collection()], forServerID: serverID)
        await snapshots.setHomeFeed(
            HomeFeedSnapshot(hero: [], continueWatching: [.movie(LibraryFixtures.movie())], nextUp: []),
            forServerID: serverID
        )
    }

    @Test("Removing a server drops its cached Home feed and libraries")
    func removePurgesSnapshots() async throws {
        try await withHarness("ServerStoreSnapshotPurgeTests.remove") { store, snapshots in
            try await store.add(JellyfinFixtures.session(id: "s1", token: "t1"))
            await seed(snapshots, serverID: "s1")

            try await store.remove(ServerID(rawValue: "s1"))

            #expect(await snapshots.homeFeed(forServerID: "s1") == nil)
            #expect(await snapshots.libraries(forServerID: "s1") == nil)
        }
    }

    @Test("A rejected token drops the cached payloads it produced")
    func invalidationPurgesSnapshots() async throws {
        try await withHarness("ServerStoreSnapshotPurgeTests.invalidate") { store, snapshots in
            try await store.add(JellyfinFixtures.session(id: "s1", token: "dead"))
            await seed(snapshots, serverID: "s1")

            await store.invalidateSession(ServerID(rawValue: "s1"))

            #expect(await snapshots.homeFeed(forServerID: "s1") == nil)
            #expect(await snapshots.libraries(forServerID: "s1") == nil)
        }
    }

    @Test("Only the removed server's snapshots go — the others keep theirs")
    func purgeIsPerServer() async throws {
        try await withHarness("ServerStoreSnapshotPurgeTests.perServer") { store, snapshots in
            try await store.add(JellyfinFixtures.session(id: "s1", token: "t1"))
            try await store.add(JellyfinFixtures.session(id: "s2", token: "t2"))
            await seed(snapshots, serverID: "s1")
            await seed(snapshots, serverID: "s2")

            try await store.remove(ServerID(rawValue: "s1"))

            #expect(await snapshots.homeFeed(forServerID: "s1") == nil)
            #expect(await snapshots.homeFeed(forServerID: "s2") != nil)
            #expect(await snapshots.libraries(forServerID: "s2") != nil)
        }
    }
}
