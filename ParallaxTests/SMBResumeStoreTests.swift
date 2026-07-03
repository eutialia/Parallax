import Foundation
import CoreMedia
import Testing
import ParallaxCore
@testable import Parallax

@Suite("SMBResumeStore")
struct SMBResumeStoreTests {

    @Test("A save under the 5s floor clears the entry instead of writing")
    func belowFloorClears() async throws {
        let suite = "SMBResumeStoreTests.belowFloorClears"
        let (store, defaults) = try SMBTestFixtures.makeResumeStore(suite: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let id = ItemID(rawValue: "smb-item-floor")

        // Seed a real position first so the sub-floor save provably CLEARS it
        // (not just fails to write).
        await store.save(position: CMTime(seconds: 120, preferredTimescale: 600),
                         duration: CMTime(seconds: 7200, preferredTimescale: 600), for: id)
        await store.save(position: CMTime(seconds: 3, preferredTimescale: 600),
                         duration: CMTime(seconds: 7200, preferredTimescale: 600), for: id)

        #expect(await store.resumeTime(for: id) == nil)
    }

    @Test("A mid-film save round-trips through resumeTime")
    func midFilmRoundTrips() async throws {
        let suite = "SMBResumeStoreTests.midFilmRoundTrips"
        let (store, defaults) = try SMBTestFixtures.makeResumeStore(suite: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let id = ItemID(rawValue: "smb-item-mid")

        await store.save(position: CMTime(seconds: 120, preferredTimescale: 600),
                         duration: CMTime(seconds: 7200, preferredTimescale: 600), for: id)

        let resumed = try #require(await store.resumeTime(for: id))
        #expect(abs(CMTimeGetSeconds(resumed) - 120) < 0.001)
    }

    @Test("A save at ≥95% of a known duration clears the entry (finished film restarts)")
    func nearEndClears() async throws {
        let suite = "SMBResumeStoreTests.nearEndClears"
        let (store, defaults) = try SMBTestFixtures.makeResumeStore(suite: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let id = ItemID(rawValue: "smb-item-end")

        // Seed mid-film so the 95.8% save provably clears an existing entry.
        await store.save(position: CMTime(seconds: 120, preferredTimescale: 600),
                         duration: CMTime(seconds: 7200, preferredTimescale: 600), for: id)
        await store.save(position: CMTime(seconds: 6900, preferredTimescale: 600),
                         duration: CMTime(seconds: 7200, preferredTimescale: 600), for: id)

        #expect(await store.resumeTime(for: id) == nil)
    }

    @Test("The 500-entry LRU cap evicts the oldest save")
    func lruCapEvictsOldest() async throws {
        let suite = "SMBResumeStoreTests.lruCapEvictsOldest"
        let (store, defaults) = try SMBTestFixtures.makeResumeStore(suite: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        // 501 saves with unknown duration (nil = no 95% rule in play).
        for n in 0...500 {
            await store.save(position: CMTime(seconds: 120, preferredTimescale: 600),
                             duration: nil, for: ItemID(rawValue: "smb-item-\(n)"))
        }

        // The first (oldest `at`) entry fell off; its neighbors survived.
        #expect(await store.resumeTime(for: ItemID(rawValue: "smb-item-0")) == nil)
        #expect(await store.resumeTime(for: ItemID(rawValue: "smb-item-1")) != nil)
        #expect(await store.resumeTime(for: ItemID(rawValue: "smb-item-500")) != nil)
    }
}
