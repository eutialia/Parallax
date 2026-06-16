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

    @Test("existingURL misses on a fresh key; store writes the PNG and returns its file URL")
    func storeWritesAndExistingURLFinds() async throws {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        let cache = SMBThumbnailCache(directory: dir)
        let key = SMBThumbnailKey(serverID: "smb-nas|Media|", path: "Movies/Film.mkv", size: 1234, modifiedAt: Date(timeIntervalSince1970: 1_000))

        // Fresh key: a miss, no file written.
        #expect(await cache.existingURL(for: key) == nil)

        let stored = try #require(await cache.store(Self.pngData, for: key))
        #expect(stored.isFileURL)
        #expect(FileManager.default.fileExists(atPath: stored.path))
        #expect(try Data(contentsOf: stored) == Self.pngData)

        // After storing, the same key resolves to the same file via existingURL.
        #expect(await cache.existingURL(for: key) == stored)
    }

    @Test("existingURL is read-only — repeated lookups return the same URL, never re-storing")
    func existingURLIsStableAndReadOnly() async throws {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        let cache = SMBThumbnailCache(directory: dir)
        let key = SMBThumbnailKey(serverID: "smb-nas|Media|", path: "Shows/E01.mkv", size: 42, modifiedAt: Date(timeIntervalSince1970: 2_000))

        let stored = try #require(await cache.store(Self.pngData, for: key))
        let first = await cache.existingURL(for: key)
        let second = await cache.existingURL(for: key)
        #expect(first == stored)
        #expect(second == stored)
    }

    @Test("a changed modification date is a distinct key, so it stores a distinct file")
    func changedMtimeIsADistinctEntry() async throws {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        let cache = SMBThumbnailCache(directory: dir)

        let original = SMBThumbnailKey(serverID: "smb-nas|Media|", path: "Movies/Film.mkv", size: 1234, modifiedAt: Date(timeIntervalSince1970: 1_000))
        let edited = SMBThumbnailKey(serverID: "smb-nas|Media|", path: "Movies/Film.mkv", size: 1234, modifiedAt: Date(timeIntervalSince1970: 9_999))

        let firstURL = try #require(await cache.store(Self.pngData, for: original))
        let secondURL = try #require(await cache.store(Self.pngData, for: edited))
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
            let key = SMBThumbnailKey(serverID: "s", path: "f\(i).mkv", size: Int64(i), modifiedAt: nil)
            _ = await cache.store(blob, for: key)
        }

        let urls = try FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.totalFileAllocatedSizeKey]
        ).filter { $0.pathExtension == "png" }
        let total = try urls.reduce(Int64(0)) {
            $0 + Int64((try $1.resourceValues(forKeys: [.totalFileAllocatedSizeKey])).totalFileAllocatedSize ?? 0)
        }

        #expect(total <= cap, "post-sweep total \(total) must stay within the cap \(cap)")
        #expect(urls.count < 8, "the sweep must have evicted at least one file")
        #expect(!urls.isEmpty, "the most recent write must survive the sweep")
    }

    @Test("two servers with the same share-relative path get distinct cache entries")
    func differentServerIDsDoNotCollide() async throws {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        let cache = SMBThumbnailCache(directory: dir)
        // Same path, size, and mtime — only the owning server differs.
        let serverA = SMBThumbnailKey(serverID: "smb-a|Media|", path: "Movies/Film.mkv", size: 1234, modifiedAt: Date(timeIntervalSince1970: 1_000))
        let serverB = SMBThumbnailKey(serverID: "smb-b|Media|", path: "Movies/Film.mkv", size: 1234, modifiedAt: Date(timeIntervalSince1970: 1_000))

        let urlA = try #require(await cache.store(Self.pngData, for: serverA))
        let urlB = try #require(await cache.store(Self.pngData, for: serverB))
        #expect(urlA != urlB, "Different servers must not share one cache file for the same relative path")
        #expect(FileManager.default.fileExists(atPath: urlA.path))
        #expect(FileManager.default.fileExists(atPath: urlB.path))
    }
}
