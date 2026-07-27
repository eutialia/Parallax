import Foundation
import Testing
@testable import ParallaxCore
import ParallaxCoreTestSupport

@Suite("SnapshotStore")
struct SnapshotStoreTests {
    /// Runs `body` against a store rooted in a throwaway directory, then deletes it. Nothing here
    /// may touch the real Application Support container — a test that wiped it would take the
    /// user's cached Home feed with it.
    private func withStore(
        schemaVersion: Int = SnapshotStore.schemaVersion,
        _ body: (SnapshotStore, URL) async throws -> Void
    ) async throws {
        let container = URL.temporaryDirectory.appending(
            path: "snapshot-store-\(UUID().uuidString)", directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: container) }
        try await body(SnapshotStore(container: container, schemaVersion: schemaVersion), container)
    }

    private func homeFeed(title: String = "Inception") -> HomeFeedSnapshot {
        HomeFeedSnapshot(
            hero: [
                HomeHeroFeedEntry(
                    presentation: .movie(LibraryFixtures.movie(title: title)),
                    playTarget: .movie(LibraryFixtures.movie(title: title)),
                    eyebrow: .newlyAdded
                ),
            ],
            continueWatching: [.episode(LibraryFixtures.episode())],
            nextUp: [.series(LibraryFixtures.series())]
        )
    }

    @Test("a Home feed survives the round trip")
    func homeFeedRoundTrip() async throws {
        try await withStore { store, _ in
            let snapshot = homeFeed()
            await store.setHomeFeed(snapshot, forServerID: "server-a")
            #expect(await store.homeFeed(forServerID: "server-a") == snapshot)
        }
    }

    @Test("library listings survive the round trip")
    func librariesRoundTrip() async throws {
        try await withStore { store, _ in
            let collections = [
                LibraryFixtures.collection(id: "movies", name: "Movies"),
                LibraryFixtures.collection(id: "shows", name: "Shows", collectionType: .tvShows),
            ]
            await store.setLibraries(collections, forServerID: "server-a")
            #expect(await store.libraries(forServerID: "server-a") == collections)
        }
    }

    @Test("a server reads only its own snapshot")
    func snapshotsArePerServer() async throws {
        try await withStore { store, _ in
            await store.setHomeFeed(homeFeed(title: "A"), forServerID: "server-a")
            await store.setHomeFeed(homeFeed(title: "B"), forServerID: "server-b")
            #expect(await store.homeFeed(forServerID: "server-a") == homeFeed(title: "A"))
            #expect(await store.homeFeed(forServerID: "server-b") == homeFeed(title: "B"))
            #expect(await store.homeFeed(forServerID: "server-c") == nil)
        }
    }

    @Test("an unwritten kind reads as nil, not as an error")
    func missingSnapshot() async throws {
        try await withStore { store, _ in
            #expect(await store.homeFeed(forServerID: "server-a") == nil)
            #expect(await store.libraries(forServerID: "server-a") == nil)
        }
    }

    @Test("a snapshot written by an older schema version is invisible and pruned")
    func schemaVersionMismatch() async throws {
        let container = URL.temporaryDirectory.appending(
            path: "snapshot-store-\(UUID().uuidString)", directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: container) }

        let old = SnapshotStore(container: container, schemaVersion: 1)
        await old.setHomeFeed(homeFeed(), forServerID: "server-a")
        #expect(old.hasCachedHomeFeed)

        // The version is part of the path, so the newer store can't even see the old file — and
        // its first touch of disk removes the dead version directory rather than leaving a copy
        // of a retired schema on the device forever.
        let new = SnapshotStore(container: container, schemaVersion: 2)
        #expect(await new.homeFeed(forServerID: "server-a") == nil)
        #expect(!new.hasCachedHomeFeed)
        #expect(!FileManager.default.fileExists(atPath: container.appending(path: "v1").path(percentEncoded: false)))
    }

    @Test("a corrupt file is discarded and deleted rather than surfaced")
    func corruptSnapshot() async throws {
        try await withStore { store, container in
            await store.setHomeFeed(homeFeed(), forServerID: "server-a")
            let file = try #require(
                FileManager.default
                    .enumerator(at: container, includingPropertiesForKeys: nil)?
                    .compactMap { $0 as? URL }
                    .first { $0.pathExtension == "json" }
            )
            try Data("not json".utf8).write(to: file)

            #expect(await store.homeFeed(forServerID: "server-a") == nil)
            // Deleted on the failed read, so the next launch doesn't pay to decode it again — and
            // the presence probe stops promising content that can't be shown.
            #expect(!FileManager.default.fileExists(atPath: file.path(percentEncoded: false)))
            #expect(!store.hasCachedHomeFeed)
        }
    }

    @Test("a payload that no longer decodes as its declared type reads as nil")
    func shapeDrift() async throws {
        try await withStore { store, _ in
            await store.save(["not", "a", "feed"], kind: .homeFeed, serverID: "server-a")
            #expect(await store.homeFeed(forServerID: "server-a") == nil)
        }
    }

    @Test("removing a server drops every kind it held, and only that server's")
    func removePerServer() async throws {
        try await withStore { store, _ in
            await store.setHomeFeed(homeFeed(), forServerID: "server-a")
            await store.setLibraries([LibraryFixtures.collection()], forServerID: "server-a")
            await store.setHomeFeed(homeFeed(), forServerID: "server-b")

            await store.removeSnapshots(forServerID: "server-a")

            #expect(await store.homeFeed(forServerID: "server-a") == nil)
            #expect(await store.libraries(forServerID: "server-a") == nil)
            #expect(await store.homeFeed(forServerID: "server-b") != nil)
        }
    }

    @Test("the presence probe answers before and after a write, per kind")
    func presenceProbe() async throws {
        try await withStore { store, _ in
            #expect(!store.hasCachedHomeFeed)

            await store.setHomeFeed(homeFeed(), forServerID: "server-a")

            #expect(store.hasCachedHomeFeed)
            // Kinds are independent — a cached library list is not a cached Home feed.
            #expect(!store.hasAnySnapshot(kind: .libraries))

            await store.removeSnapshots(forServerID: "server-a")
            #expect(!store.hasCachedHomeFeed)
        }
    }

    @Test("a rewrite replaces the previous payload rather than appending to it")
    func overwrite() async throws {
        try await withStore { store, _ in
            await store.setHomeFeed(homeFeed(title: "First"), forServerID: "server-a")
            await store.setHomeFeed(homeFeed(title: "Second"), forServerID: "server-a")
            #expect(await store.homeFeed(forServerID: "server-a") == homeFeed(title: "Second"))
        }
    }

    @Test("server ids that aren't safe file names still round-trip distinctly")
    func hostileServerIDs() async throws {
        try await withStore { store, _ in
            await store.setHomeFeed(homeFeed(title: "slash"), forServerID: "smb-/nas/media")
            await store.setHomeFeed(homeFeed(title: "dots"), forServerID: "../../etc")
            #expect(await store.homeFeed(forServerID: "smb-/nas/media") == homeFeed(title: "slash"))
            #expect(await store.homeFeed(forServerID: "../../etc") == homeFeed(title: "dots"))
        }
    }
}
