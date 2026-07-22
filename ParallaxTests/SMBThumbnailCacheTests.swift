import Foundation
import Testing
@testable import Parallax

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

    /// A fresh temp directory, removed at the end of each test.
    private func makeTempDir() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("smb-thumb-tests-\(UUID().uuidString)", isDirectory: true)
    }

    private func cleanup(_ dir: URL) {
        try? FileManager.default.removeItem(at: dir)
    }

    @Test("existing misses on a fresh key; store writes the PNG and returns its file URL")
    func storeWritesAndExistingFinds() async throws {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        let cache = SMBThumbnailCache(directory: dir)
        let key = SMBThumbnailKey(serverID: "smb-nas", share: "Media", path: "Movies/Film.mkv", size: 1234, modifiedAt: Date(timeIntervalSince1970: 1_000))

        // Fresh key: a miss, no file written.
        #expect(await cache.existing(for: key) == nil)

        let stored = try #require(await cache.store(Self.pngData, duration: nil, for: key))
        #expect(stored.url.isFileURL)
        #expect(FileManager.default.fileExists(atPath: stored.url.path))
        #expect(try Data(contentsOf: stored.url) == Self.pngData)

        // After storing, the same key resolves to the same file via existing.
        #expect(await cache.existing(for: key) == stored)
    }

    @Test("store persists the duration; existing reads it back from the sidecar")
    func durationRoundTrips() async throws {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        let cache = SMBThumbnailCache(directory: dir)
        let key = SMBThumbnailKey(serverID: "smb-nas", share: "Media", path: "Movies/Film.mkv", size: 1234, modifiedAt: Date(timeIntervalSince1970: 1_000))

        let duration = Duration.seconds(5_025)  // 1h 23m 45s — sub-minute precision survives the ms round-trip
        let stored = try #require(await cache.store(Self.pngData, duration: duration, for: key))
        #expect(stored.duration == duration)

        // A fresh peek reads the duration back from the `.dur` sidecar, not from memory.
        let hit = try #require(await cache.existing(for: key))
        #expect(hit.duration == duration)
    }

    @Test("a store with no duration round-trips a nil duration (no sidecar)")
    func absentDurationIsNil() async throws {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        let cache = SMBThumbnailCache(directory: dir)
        let key = SMBThumbnailKey(serverID: "smb-nas", share: "Media", path: "Shows/E02.mkv", size: 7, modifiedAt: nil)

        _ = try #require(await cache.store(Self.pngData, duration: nil, for: key))
        let hit = try #require(await cache.existing(for: key))
        #expect(hit.duration == nil)
    }

    @Test("existing is read-only — repeated lookups return the same URL, never re-storing")
    func existingIsStableAndReadOnly() async throws {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        let cache = SMBThumbnailCache(directory: dir)
        let key = SMBThumbnailKey(serverID: "smb-nas", share: "Media", path: "Shows/E01.mkv", size: 42, modifiedAt: Date(timeIntervalSince1970: 2_000))

        let stored = try #require(await cache.store(Self.pngData, duration: nil, for: key))
        let first = await cache.existing(for: key)
        let second = await cache.existing(for: key)
        #expect(first?.url == stored.url)
        #expect(second?.url == stored.url)
    }

    @Test("a changed modification date is a distinct key, so it stores a distinct file")
    func changedMtimeIsADistinctEntry() async throws {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        let cache = SMBThumbnailCache(directory: dir)

        let original = SMBThumbnailKey(serverID: "smb-nas", share: "Media", path: "Movies/Film.mkv", size: 1234, modifiedAt: Date(timeIntervalSince1970: 1_000))
        let edited = SMBThumbnailKey(serverID: "smb-nas", share: "Media", path: "Movies/Film.mkv", size: 1234, modifiedAt: Date(timeIntervalSince1970: 9_999))

        let firstURL = try #require(await cache.store(Self.pngData, duration: nil, for: original)).url
        let secondURL = try #require(await cache.store(Self.pngData, duration: nil, for: edited)).url
        #expect(firstURL != secondURL)
        #expect(FileManager.default.fileExists(atPath: firstURL.path))
        #expect(FileManager.default.fileExists(atPath: secondURL.path))
    }

    @Test("bounded LRU: the cache sweeps to stay within its size cap, keeping the newest")
    func boundedEviction() async throws {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        // 16 KB blobs sit comfortably above the filesystem block floor, so byte math holds
        // regardless of allocation rounding. Cap holds ~3; trim toward ~1; sweep every store.
        let blob = Data(count: 16 * 1024)
        let cap = Int64(blob.count) * 3
        let cache = SMBThumbnailCache(
            directory: dir,
            sizeCapBytes: cap,
            trimTargetBytes: Int64(blob.count),
            sweepInterval: 1
        )

        for i in 0..<8 {
            let key = SMBThumbnailKey(serverID: "s", share: "Media", path: "f\(i).mkv", size: Int64(i), modifiedAt: nil)
            _ = await cache.store(blob, duration: nil, for: key)
        }

        let urls = try FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.totalFileAllocatedSizeKey]
        ).filter { $0.pathExtension == "heic" }
        let total = try urls.reduce(Int64(0)) {
            $0 + Int64((try $1.resourceValues(forKeys: [.totalFileAllocatedSizeKey])).totalFileAllocatedSize ?? 0)
        }

        #expect(total <= cap, "post-sweep total \(total) must stay within the cap \(cap)")
        #expect(urls.count < 8, "the sweep must have evicted at least one file")
        #expect(!urls.isEmpty, "the most recent write must survive the sweep")
    }

    @Test("sweep co-evicts each image's .dur sidecar — no orphans, sidecars excluded from the cap")
    func sweepCoEvictsSidecars() async throws {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        let blob = Data(count: 16 * 1024)
        let cap = Int64(blob.count) * 3
        let cache = SMBThumbnailCache(
            directory: dir,
            sizeCapBytes: cap,
            trimTargetBytes: Int64(blob.count),
            sweepInterval: 1
        )

        // Every store carries a positive duration, so each image also writes a .dur sidecar.
        for i in 0..<8 {
            let key = SMBThumbnailKey(serverID: "s", share: "Media", path: "f\(i).mkv", size: Int64(i), modifiedAt: nil)
            _ = await cache.store(blob, duration: .seconds(60 + i), for: key)
        }

        let entries = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.totalFileAllocatedSizeKey])
        let images = entries.filter { $0.pathExtension == "heic" }
        let durs = entries.filter { $0.pathExtension == "dur" }

        #expect(images.count < 8, "the sweep must have evicted at least one image")
        #expect(!images.isEmpty, "the most recent write must survive the sweep")
        // Each evicted image drops its sidecar and each survivor keeps its own — so the two counts
        // match, i.e. no orphaned .dur is left behind.
        #expect(durs.count == images.count, "sidecars must track images 1:1 after sweep (no orphans)")

        // Sidecars (tens of bytes) must not count toward the cap: the surviving image bytes hold within it.
        let imageBytes = try images.reduce(Int64(0)) {
            $0 + Int64((try $1.resourceValues(forKeys: [.totalFileAllocatedSizeKey])).totalFileAllocatedSize ?? 0)
        }
        #expect(imageBytes <= cap, "surviving image bytes \(imageBytes) must stay within the cap \(cap)")
    }

    @Test("totalSize sums cached files; clear wipes them, recreating the dir on the next store")
    func clearWipesCacheAndSize() async throws {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        let cache = SMBThumbnailCache(directory: dir)

        #expect(await cache.totalSize() == 0)  // nothing stored yet

        let blob = Data(count: 4 * 1024)
        for i in 0..<3 {
            let key = SMBThumbnailKey(serverID: "s", share: "Media", path: "f\(i).mkv", size: Int64(i), modifiedAt: nil)
            _ = await cache.store(blob, duration: .seconds(60 + i), for: key)  // PNG + .dur sidecar each
        }
        #expect(await cache.totalSize() > 0, "stored files should count toward the size")

        await cache.clear()
        #expect(await cache.totalSize() == 0, "clear must wipe the cache")

        // A previously-stored key now misses, and a fresh store still works (dir recreated).
        let key = SMBThumbnailKey(serverID: "s", share: "Media", path: "f0.mkv", size: 0, modifiedAt: nil)
        #expect(await cache.existing(for: key) == nil)
        #expect(try #require(await cache.store(blob, duration: nil, for: key)).url.isFileURL,
                "store must recreate the directory after a clear")
    }

    @Test("store writes a .heic file for a new key")
    func storeWritesHEIC() async throws {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        let cache = SMBThumbnailCache(directory: dir)
        let key = SMBThumbnailKey(serverID: "smb-nas", share: "Media", path: "Movies/Film.mkv", size: 1234, modifiedAt: Date(timeIntervalSince1970: 1_000))

        let stored = try #require(await cache.store(Self.pngData, duration: nil, for: key))
        #expect(stored.url.pathExtension == "heic", "new writes use the .heic extension")
    }

    @Test("existing falls back to a legacy .png when no .heic exists")
    func existingFallsBackToLegacyPNG() async throws {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        let cache = SMBThumbnailCache(directory: dir)
        let key = SMBThumbnailKey(serverID: "smb-nas", share: "Media", path: "Movies/Old.mkv", size: 55, modifiedAt: Date(timeIntervalSince1970: 3_000))

        // Simulate a pre-HEIC cache entry at this key's exact base name: store writes the .heic, then
        // move it to .png so only the legacy extension remains on disk.
        let seeded = try #require(await cache.store(Self.pngData, duration: nil, for: key))
        let legacyPNG = seeded.url.deletingPathExtension().appendingPathExtension("png")
        try FileManager.default.moveItem(at: seeded.url, to: legacyPNG)

        // existing() must find the legacy PNG (no .heic present) and return its URL.
        let hit = try #require(await cache.existing(for: key))
        #expect(hit.url.pathExtension == "png")
        #expect(hit.url == legacyPNG)

        // A later store writes a .heic; existing() then prefers the .heic over the surviving legacy PNG.
        let stored = try #require(await cache.store(Self.pngData, duration: nil, for: key))
        #expect(stored.url.pathExtension == "heic")
        let afterStore = try #require(await cache.existing(for: key))
        #expect(afterStore.url.pathExtension == "heic", "a .heic shadows the legacy .png once written")
    }

    @Test("failure markers accumulate attempts, survive as a file, and clear on store")
    func failureMarkersLifecycle() async throws {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        let cache = SMBThumbnailCache(directory: dir)
        let key = SMBThumbnailKey(serverID: "smb-nas", share: "Media", path: "Broken/File.mkv", size: 9, modifiedAt: Date(timeIntervalSince1970: 4_000))

        // No marker on a fresh key.
        #expect(await cache.failureState(for: key) == nil)

        let before = Date()
        await cache.recordFailure(for: key)
        let first = try #require(await cache.failureState(for: key))
        #expect(first.attempts == 1)
        #expect(first.lastAttempt.timeIntervalSince(before) >= -1, "lastAttempt is stamped ~now")

        await cache.recordFailure(for: key)
        #expect(try #require(await cache.failureState(for: key)).attempts == 2, "attempts accumulate")

        // A successful store clears the marker (the file just proved decodable).
        _ = try #require(await cache.store(Self.pngData, duration: nil, for: key))
        #expect(await cache.failureState(for: key) == nil, "store clears the failure marker")

        // A post-success failure re-records from a fresh count (store wiped the history).
        let restarted = await cache.recordFailure(for: key)
        #expect(restarted.attempts == 1, "a cleared marker restarts at attempt 1, not the old count")
    }

    @Test("clear() wipes failure markers too")
    func clearWipesFailureMarkers() async throws {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        let cache = SMBThumbnailCache(directory: dir)
        let key = SMBThumbnailKey(serverID: "s", share: "Media", path: "x.mkv", size: 1, modifiedAt: nil)
        await cache.recordFailure(for: key)
        #expect(await cache.failureState(for: key) != nil)
        await cache.clear()
        #expect(await cache.failureState(for: key) == nil, "clear() drops persistent failure markers")
    }

    @Test("two servers with the same share-relative path get distinct cache entries")
    func differentServerIDsDoNotCollide() async throws {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        let cache = SMBThumbnailCache(directory: dir)
        // Same share, path, size, and mtime — only the owning server differs.
        let serverA = SMBThumbnailKey(serverID: "smb-a", share: "Media", path: "Movies/Film.mkv", size: 1234, modifiedAt: Date(timeIntervalSince1970: 1_000))
        let serverB = SMBThumbnailKey(serverID: "smb-b", share: "Media", path: "Movies/Film.mkv", size: 1234, modifiedAt: Date(timeIntervalSince1970: 1_000))

        let urlA = try #require(await cache.store(Self.pngData, duration: nil, for: serverA)).url
        let urlB = try #require(await cache.store(Self.pngData, duration: nil, for: serverB)).url
        #expect(urlA != urlB, "Different servers must not share one cache file for the same relative path")
        #expect(FileManager.default.fileExists(atPath: urlA.path))
        #expect(FileManager.default.fileExists(atPath: urlB.path))
    }

    @Test("two shares on ONE host with the same relative path get distinct cache entries")
    func differentSharesDoNotCollide() async throws {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        let cache = SMBThumbnailCache(directory: dir)
        // One host now maps to one serverID ("smb-<host>"), so the share is the only discriminator
        // here. Without it in the key these two files would overwrite each other's frame-grab — the
        // cross-share collision the share-hierarchy migration introduced.
        let media = SMBThumbnailKey(serverID: "smb-nas", share: "Media", path: "Movies/Film.mkv", size: 1234, modifiedAt: Date(timeIntervalSince1970: 1_000))
        let backups = SMBThumbnailKey(serverID: "smb-nas", share: "Backups", path: "Movies/Film.mkv", size: 1234, modifiedAt: Date(timeIntervalSince1970: 1_000))

        let urlMedia = try #require(await cache.store(Self.pngData, duration: nil, for: media)).url
        let urlBackups = try #require(await cache.store(Self.pngData, duration: nil, for: backups)).url
        #expect(urlMedia != urlBackups, "Two shares on one host must not share one cache file for the same relative path")
        #expect(FileManager.default.fileExists(atPath: urlMedia.path))
        #expect(FileManager.default.fileExists(atPath: urlBackups.path))
    }
}
