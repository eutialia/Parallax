import Foundation
import Testing
@testable import Parallax

@Suite("SMBThumbnailCache")
struct SMBThumbnailCacheTests {

    /// Smallest valid PNG: a 1×1 transparent image. Lets a test assert the cache
    /// round-trips the generator's exact bytes without depending on VLC.
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

    /// Counts generator invocations across concurrency domains.
    private actor CallCounter {
        private(set) var count = 0
        func increment() { count += 1 }
    }

    /// A fresh temp directory, removed at the end of each test.
    private func makeTempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("smb-thumb-tests-\(UUID().uuidString)", isDirectory: true)
        return dir
    }

    private func cleanup(_ dir: URL) {
        try? FileManager.default.removeItem(at: dir)
    }

    @Test("miss generates, writes the PNG to disk, returns the file URL once")
    func missGeneratesAndWrites() async throws {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        let cache = SMBThumbnailCache(directory: dir)
        let counter = CallCounter()
        let key = SMBThumbnailKey(path: "Movies/Film.mkv", size: 1234, modifiedAt: Date(timeIntervalSince1970: 1_000))

        let url = await cache.thumbnailURL(for: key) {
            await counter.increment()
            return Self.pngData
        }

        let resolved = try #require(url)
        #expect(FileManager.default.fileExists(atPath: resolved.path))
        #expect(resolved.isFileURL)
        #expect(try Data(contentsOf: resolved) == Self.pngData)
        #expect(await counter.count == 1)
    }

    @Test("hit returns the cached URL without regenerating")
    func hitDoesNotRegenerate() async throws {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        let cache = SMBThumbnailCache(directory: dir)
        let counter = CallCounter()
        let key = SMBThumbnailKey(path: "Shows/E01.mkv", size: 42, modifiedAt: Date(timeIntervalSince1970: 2_000))

        let generate: () async throws -> Data = {
            await counter.increment()
            return Self.pngData
        }

        let first = await cache.thumbnailURL(for: key, generate: generate)
        let second = await cache.thumbnailURL(for: key, generate: generate)

        #expect(first != nil)
        #expect(first == second)
        #expect(await counter.count == 1)
    }

    @Test("a changed modification date is a new key, so it regenerates")
    func changedMtimeRegenerates() async throws {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        let cache = SMBThumbnailCache(directory: dir)
        let counter = CallCounter()
        let generate: () async throws -> Data = {
            await counter.increment()
            return Self.pngData
        }

        let original = SMBThumbnailKey(path: "Movies/Film.mkv", size: 1234, modifiedAt: Date(timeIntervalSince1970: 1_000))
        let edited = SMBThumbnailKey(path: "Movies/Film.mkv", size: 1234, modifiedAt: Date(timeIntervalSince1970: 9_999))

        let firstURL = await cache.thumbnailURL(for: original, generate: generate)
        let secondURL = await cache.thumbnailURL(for: edited, generate: generate)

        #expect(firstURL != nil)
        #expect(secondURL != nil)
        #expect(firstURL != secondURL)
        #expect(await counter.count == 2)
    }

    @Test("a throwing generator returns nil and writes no file")
    func generatorThrowsReturnsNil() async throws {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        let cache = SMBThumbnailCache(directory: dir)
        let counter = CallCounter()
        let key = SMBThumbnailKey(path: "Movies/Broken.mkv", size: 7, modifiedAt: nil)

        struct GenerationError: Error {}
        let url = await cache.thumbnailURL(for: key) {
            await counter.increment()
            throw GenerationError()
        }

        #expect(url == nil)
        #expect(await counter.count == 1)
        // No artifact should be left behind for this key.
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        #expect(contents.allSatisfy { !$0.hasSuffix(".png") })
    }
}
