import Foundation
import CoreMedia
import Testing
import ParallaxCore
@testable import Parallax

@Suite("SMBResumeStore")
struct SMBResumeStoreTests {
    /// Two hours, the reference runtime every position below is expressed against.
    private static let runtime = CMTime(seconds: 7200, preferredTimescale: 600)

    private static func seconds(_ value: Double) -> CMTime {
        CMTime(seconds: value, preferredTimescale: 600)
    }

    @Test("A save under the minimum-progress floor clears the entry instead of writing")
    func belowFloorClears() async throws {
        try await SMBTestFixtures.withResumeStore(suite: #function) { store in
            let id = ItemID(rawValue: "smb-item-floor")

            // Seed a real position first so the sub-floor save provably CLEARS it (not just fails
            // to write). The sub-floor position is derived from the store's own floor, so raising
            // the floor can't leave this test quietly asserting nothing.
            await store.save(position: Self.seconds(120), duration: Self.runtime, for: id)
            await store.save(
                position: Self.seconds(SMBResumeStore.minimumProgressSeconds - 1),
                duration: Self.runtime,
                for: id
            )

            #expect(await store.resumeTime(for: id) == nil)
        }
    }

    /// The floor is inclusive: a position exactly AT it is real progress and must survive. Pinned
    /// separately from the below-floor case because an off-by-one in the comparison is invisible to
    /// both a mid-film save and a 1-second one.
    @Test("A save exactly at the floor is kept")
    func atFloorPersists() async throws {
        try await SMBTestFixtures.withResumeStore(suite: #function) { store in
            let id = ItemID(rawValue: "smb-item-at-floor")
            let floor = SMBResumeStore.minimumProgressSeconds

            await store.save(position: Self.seconds(floor), duration: Self.runtime, for: id)

            let resumed = try #require(await store.resumeTime(for: id))
            #expect(abs(CMTimeGetSeconds(resumed) - floor) < 0.001)
        }
    }

    @Test("A mid-film save round-trips through resumeTime")
    func midFilmRoundTrips() async throws {
        try await SMBTestFixtures.withResumeStore(suite: #function) { store in
            let id = ItemID(rawValue: "smb-item-mid")

            await store.save(position: Self.seconds(120), duration: Self.runtime, for: id)

            let resumed = try #require(await store.resumeTime(for: id))
            #expect(abs(CMTimeGetSeconds(resumed) - 120) < 0.001)
        }
    }

    @Test("A save at the completion fraction of a known duration clears the entry (finished film restarts)")
    func nearEndClears() async throws {
        try await SMBTestFixtures.withResumeStore(suite: #function) { store in
            let id = ItemID(rawValue: "smb-item-end")
            let total = CMTimeGetSeconds(Self.runtime)

            // Seed mid-film so the completion-fraction save provably clears an existing entry. The
            // position is derived from the store's own fraction rather than a hand-computed 6900.
            await store.save(position: Self.seconds(120), duration: Self.runtime, for: id)
            await store.save(
                position: Self.seconds(total * SMBResumeStore.completionFraction),
                duration: Self.runtime,
                for: id
            )

            #expect(await store.resumeTime(for: id) == nil)
        }
    }

    /// A nil/indefinite duration skips the completion rule outright — an incomplete file's estimated
    /// runtime must never wipe real progress.
    @Test("An unknown duration never triggers the completion clear")
    func unknownDurationKeepsNearEndSave() async throws {
        try await SMBTestFixtures.withResumeStore(suite: #function) { store in
            let id = ItemID(rawValue: "smb-item-unknown-duration")
            let total = CMTimeGetSeconds(Self.runtime)

            await store.save(
                position: Self.seconds(total * SMBResumeStore.completionFraction),
                duration: nil,
                for: id
            )

            #expect(await store.resumeTime(for: id) != nil)
        }
    }

    @Test("The LRU cap evicts the oldest save")
    func lruCapEvictsOldest() async throws {
        try await SMBTestFixtures.withResumeStore(suite: #function) { store in
            // One save past the cap, with unknown durations so the completion rule stays out of it.
            let cap = SMBResumeStore.maxEntries
            for n in 0...cap {
                await store.save(position: Self.seconds(120), duration: nil, for: ItemID(rawValue: "smb-item-\(n)"))
            }

            // The first (oldest `at`) entry fell off; its neighbour and the newest survived.
            #expect(await store.resumeTime(for: ItemID(rawValue: "smb-item-0")) == nil)
            #expect(await store.resumeTime(for: ItemID(rawValue: "smb-item-1")) != nil)
            #expect(await store.resumeTime(for: ItemID(rawValue: "smb-item-\(cap)")) != nil)
        }
    }
}
