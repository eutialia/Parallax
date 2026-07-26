import Foundation
import Testing
@testable import Parallax

/// One key field that must participate in the cache's file name, and the pair of keys that differ
/// only in it. A named case rather than a tuple because Swift Testing only destructures 2-tuples.
struct KeyDiscriminatorCase: Sendable, CustomTestStringConvertible {
    let name: String
    let first: SMBThumbnailKey
    let second: SMBThumbnailKey
    var testDescription: String { name }
}

private let keyDiscriminatorCases: [KeyDiscriminatorCase] = [
    // One host maps to one serverID ("smb-<host>"), so two NAS boxes over a mirrored layout would
    // otherwise overwrite each other's frame-grab.
    KeyDiscriminatorCase(
        name: "serverID",
        first: SMBTestFixtures.thumbnailKey(serverID: "smb-a"),
        second: SMBTestFixtures.thumbnailKey(serverID: "smb-b")
    ),
    // The cross-share collision the share-hierarchy migration introduced: same host, same relative
    // path, different share.
    KeyDiscriminatorCase(
        name: "share",
        first: SMBTestFixtures.thumbnailKey(share: "Media"),
        second: SMBTestFixtures.thumbnailKey(share: "Backups")
    ),
    KeyDiscriminatorCase(
        name: "path",
        first: SMBTestFixtures.thumbnailKey(path: "Movies/Film.mkv"),
        second: SMBTestFixtures.thumbnailKey(path: "Shows/Film.mkv")
    ),
    // Size + mtime are what make a key self-invalidating: an edited file is a NEW cache entry rather
    // than a stale frame under the old name.
    KeyDiscriminatorCase(
        name: "size",
        first: SMBTestFixtures.thumbnailKey(size: 1234),
        second: SMBTestFixtures.thumbnailKey(size: 5678)
    ),
    KeyDiscriminatorCase(
        name: "modification date",
        first: SMBTestFixtures.thumbnailKey(modifiedAt: Date(timeIntervalSince1970: 1_000)),
        second: SMBTestFixtures.thumbnailKey(modifiedAt: Date(timeIntervalSince1970: 9_999))
    ),
]

@Suite("SMBThumbnailCache")
struct SMBThumbnailCacheTests {

    /// Smallest valid PNG: a 1×1 transparent image. Lets a test assert the cache round-trips the
    /// exact bytes without depending on VLC.
    private static let onePixelPNG: [UInt8] = [
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, // signature
        0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52, // IHDR length + type
        0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, // 1×1
        0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, // bit depth/colour + CRC
        0x89, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x44, 0x41, // IDAT length + type
        0x54, 0x78, 0x9C, 0x62, 0x00, 0x01, 0x00, 0x00, // zlib stream
        0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, // IDAT CRC
        0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, // IEND
        0x42, 0x60, 0x82,
    ]

    private static var pngData: Data { Data(onePixelPNG) }

    /// Blobs sized well above the filesystem block floor, so the byte math in the eviction tests
    /// holds regardless of allocation rounding.
    private static let blob = Data(count: 16 * 1024)

    @Test("existing misses on a fresh key; store writes the image and returns its file URL")
    func storeWritesAndExistingFinds() async throws {
        try await SMBTestFixtures.withThumbnailCache { cache, _ in
            let key = SMBTestFixtures.thumbnailKey()

            // Fresh key: a miss, no file written.
            #expect(await cache.existing(for: key) == nil)

            let stored = try #require(await cache.store(Self.pngData, duration: nil, for: key))
            #expect(stored.url.isFileURL)
            // The extension comes from the cache's own table, not a re-typed "heic".
            #expect(stored.url.pathExtension == SMBThumbnailCache.currentImageExtension)
            #expect(FileManager.default.fileExists(atPath: stored.url.path))
            #expect(try Data(contentsOf: stored.url) == Self.pngData)

            // After storing, the same key resolves to the same file via existing.
            #expect(await cache.existing(for: key) == stored)
        }
    }

    @Test("store persists the duration; existing reads it back from the sidecar")
    func durationRoundTrips() async throws {
        try await SMBTestFixtures.withThumbnailCache { cache, _ in
            let key = SMBTestFixtures.thumbnailKey()
            let duration = Duration.seconds(5_025)  // 1h 23m 45s — sub-minute precision survives the ms round-trip

            let stored = try #require(await cache.store(Self.pngData, duration: duration, for: key))
            #expect(stored.duration == duration)

            // A fresh peek reads the duration back from the `.dur` sidecar, not from memory.
            let hit = try #require(await cache.existing(for: key))
            #expect(hit.duration == duration)
        }
    }

    @Test("a store with no duration round-trips a nil duration (no sidecar)")
    func absentDurationIsNil() async throws {
        try await SMBTestFixtures.withThumbnailCache { cache, _ in
            let key = SMBTestFixtures.thumbnailKey(path: "Shows/E02.mkv", size: 7, modifiedAt: nil)

            _ = try #require(await cache.store(Self.pngData, duration: nil, for: key))
            let hit = try #require(await cache.existing(for: key))
            #expect(hit.duration == nil)
        }
    }

    @Test("existing is read-only — repeated lookups return the same URL, never re-storing")
    func existingIsStableAndReadOnly() async throws {
        try await SMBTestFixtures.withThumbnailCache { cache, _ in
            let key = SMBTestFixtures.thumbnailKey(path: "Shows/E01.mkv", size: 42)

            let stored = try #require(await cache.store(Self.pngData, duration: nil, for: key))
            let first = await cache.existing(for: key)
            let second = await cache.existing(for: key)
            #expect(first?.url == stored.url)
            #expect(second?.url == stored.url)
        }
    }

    /// Every field of the key has to reach the file name. A discriminator dropped from the hash
    /// shows up as one file overwriting another's frame-grab — invisible until a user sees the
    /// wrong thumbnail on the wrong file.
    @Test("varying one key field alone yields a distinct cache file", arguments: keyDiscriminatorCases)
    func keyFieldsDiscriminate(_ discriminator: KeyDiscriminatorCase) async throws {
        try await SMBTestFixtures.withThumbnailCache { cache, _ in
            let firstURL = try #require(await cache.store(Self.pngData, duration: nil, for: discriminator.first)).url
            let secondURL = try #require(await cache.store(Self.pngData, duration: nil, for: discriminator.second)).url

            #expect(firstURL != secondURL, "\(discriminator.name) must participate in the cache file name")
            // Both survive: this is a distinct entry, not an overwrite.
            #expect(FileManager.default.fileExists(atPath: firstURL.path))
            #expect(FileManager.default.fileExists(atPath: secondURL.path))
        }
    }

    /// The sweep's survivor set is fully determined, so it's asserted exactly rather than as a count
    /// band. Cap holds 3 blobs, the trim target is 1, and the sweep runs on every store:
    /// f0…f2 fit, f3 trips the cap and evicts f0–f2 down to itself, f4/f5 refill, f6 trips it again
    /// and evicts f3–f5, and f7 lands on top. Survivors: exactly f6 and f7.
    @Test("bounded LRU: the sweep trims to the target, keeping exactly the newest writes")
    func boundedEviction() async throws {
        try await SMBTestFixtures.withThumbnailCache(
            sizeCapBytes: Int64(Self.blob.count) * 3,
            trimTargetBytes: Int64(Self.blob.count),
            sweepInterval: 1
        ) { cache, directory in
            var storedURLs: [URL] = []
            for i in 0..<8 {
                let key = SMBTestFixtures.thumbnailKey(serverID: "s", path: "f\(i).mkv", size: Int64(i), modifiedAt: nil)
                storedURLs.append(try #require(await cache.store(Self.blob, duration: nil, for: key)).url)
            }

            let survivors = try Self.imageFiles(in: directory)
            #expect(Set(survivors) == Set(storedURLs.suffix(2)))
        }
    }

    @Test("sweep co-evicts each image's .dur sidecar — no orphans, sidecars excluded from the cap")
    func sweepCoEvictsSidecars() async throws {
        let cap = Int64(Self.blob.count) * 3
        try await SMBTestFixtures.withThumbnailCache(
            sizeCapBytes: cap,
            trimTargetBytes: Int64(Self.blob.count),
            sweepInterval: 1
        ) { cache, directory in
            // Every store carries a positive duration, so each image also writes a .dur sidecar.
            var storedURLs: [URL] = []
            for i in 0..<8 {
                let key = SMBTestFixtures.thumbnailKey(serverID: "s", path: "f\(i).mkv", size: Int64(i), modifiedAt: nil)
                storedURLs.append(try #require(await cache.store(Self.blob, duration: .seconds(60 + i), for: key)).url)
            }

            let entries = try FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.totalFileAllocatedSizeKey]
            )
            let images = entries.filter { SMBThumbnailCache.imageExtensions.contains($0.pathExtension) }
            let durs = entries.filter { $0.pathExtension == "dur" }

            // Same determinism as `boundedEviction`: exactly the last two writes survive.
            #expect(Set(images) == Set(storedURLs.suffix(2)))
            // Each evicted image drops its sidecar and each survivor keeps its own, so the sidecars
            // sit on exactly the surviving base names — no orphan, no missing one.
            #expect(Set(durs.map { $0.deletingPathExtension() }) == Set(images.map { $0.deletingPathExtension() }))

            // Sidecars (tens of bytes) must not count toward the cap: the surviving image bytes hold
            // within it even though the sidecars push the directory total past it.
            let imageBytes = try Self.allocatedBytes(of: images)
            #expect(imageBytes <= cap, "surviving image bytes \(imageBytes) must stay within the cap \(cap)")
        }
    }

    @Test("totalSize sums cached files; clear wipes them, recreating the dir on the next store")
    func clearWipesCacheAndSize() async throws {
        try await SMBTestFixtures.withThumbnailCache { cache, _ in
            #expect(await cache.totalSize() == 0)  // nothing stored yet

            let blob = Data(count: 4 * 1024)
            for i in 0..<3 {
                let key = SMBTestFixtures.thumbnailKey(serverID: "s", path: "f\(i).mkv", size: Int64(i), modifiedAt: nil)
                _ = await cache.store(blob, duration: .seconds(60 + i), for: key)  // image + .dur sidecar each
            }
            #expect(await cache.totalSize() > 0, "stored files should count toward the size")

            await cache.clear()
            #expect(await cache.totalSize() == 0, "clear must wipe the cache")

            // A previously-stored key now misses, and a fresh store still works (dir recreated).
            let key = SMBTestFixtures.thumbnailKey(serverID: "s", path: "f0.mkv", size: 0, modifiedAt: nil)
            #expect(await cache.existing(for: key) == nil)
            let reStored = try #require(await cache.store(blob, duration: nil, for: key))
            #expect(reStored.url.isFileURL, "store must recreate the directory after a clear")
        }
    }

    /// The pre-HEIC migration path: regenerating a whole wall at ~11s/tile over VPN just because the
    /// codec changed would be hostile, so a legacy image at the same base name still reads — and a
    /// later write in the current codec shadows it.
    @Test("existing honours a legacy-extension image, and a current-codec write shadows it")
    func existingFallsBackToLegacyImage() async throws {
        try await SMBTestFixtures.withThumbnailCache { cache, _ in
            let key = SMBTestFixtures.thumbnailKey(path: "Movies/Old.mkv", size: 55, modifiedAt: Date(timeIntervalSince1970: 3_000))
            let legacy = SMBThumbnailCache.legacyImageExtension
            let current = SMBThumbnailCache.currentImageExtension

            // Simulate a pre-HEIC entry at this key's exact base name: store writes the current
            // extension, then move it to the legacy one so only that remains on disk.
            let seeded = try #require(await cache.store(Self.pngData, duration: nil, for: key))
            let legacyURL = seeded.url.deletingPathExtension().appendingPathExtension(legacy)
            try FileManager.default.moveItem(at: seeded.url, to: legacyURL)

            let hit = try #require(await cache.existing(for: key))
            #expect(hit.url == legacyURL)

            // A later store writes the current codec; existing() then prefers it over the survivor.
            let stored = try #require(await cache.store(Self.pngData, duration: nil, for: key))
            #expect(stored.url.pathExtension == current)
            let afterStore = try #require(await cache.existing(for: key))
            #expect(afterStore.url.pathExtension == current, "the current codec shadows the legacy image once written")
        }
    }

    @Test("failure markers accumulate attempts, survive as a file, and clear on store")
    func failureMarkersLifecycle() async throws {
        try await SMBTestFixtures.withThumbnailCache { cache, _ in
            let key = SMBTestFixtures.thumbnailKey(path: "Broken/File.mkv", size: 9, modifiedAt: Date(timeIntervalSince1970: 4_000))

            // No marker on a fresh key.
            #expect(await cache.failureState(for: key) == nil)

            let before = Date()
            await cache.recordFailure(for: key)
            let first = try #require(await cache.failureState(for: key))
            #expect(first.attempts == 1)
            #expect(first.lastAttempt.timeIntervalSince(before) >= -1, "lastAttempt is stamped ~now")

            await cache.recordFailure(for: key)
            let second = try #require(await cache.failureState(for: key))
            #expect(second.attempts == 2, "attempts accumulate")

            // A successful store clears the marker (the file just proved decodable).
            _ = try #require(await cache.store(Self.pngData, duration: nil, for: key))
            #expect(await cache.failureState(for: key) == nil, "store clears the failure marker")

            // A post-success failure re-records from a fresh count (store wiped the history).
            let restarted = await cache.recordFailure(for: key)
            #expect(restarted.attempts == 1, "a cleared marker restarts at attempt 1, not the old count")
        }
    }

    @Test("clear() wipes failure markers too")
    func clearWipesFailureMarkers() async throws {
        try await SMBTestFixtures.withThumbnailCache { cache, _ in
            let key = SMBTestFixtures.thumbnailKey(serverID: "s", path: "x.mkv", size: 1, modifiedAt: nil)
            await cache.recordFailure(for: key)
            #expect(await cache.failureState(for: key) != nil)
            await cache.clear()
            #expect(await cache.failureState(for: key) == nil, "clear() drops persistent failure markers")
        }
    }

    // MARK: - Directory helpers

    private static func imageFiles(in directory: URL) throws -> [URL] {
        try FileManager.default
            .contentsOfDirectory(at: directory, includingPropertiesForKeys: [.totalFileAllocatedSizeKey])
            .filter { SMBThumbnailCache.imageExtensions.contains($0.pathExtension) }
    }

    private static func allocatedBytes(of urls: [URL]) throws -> Int64 {
        try urls.reduce(Int64(0)) {
            $0 + Int64((try $1.resourceValues(forKeys: [.totalFileAllocatedSizeKey])).totalFileAllocatedSize ?? 0)
        }
    }
}
