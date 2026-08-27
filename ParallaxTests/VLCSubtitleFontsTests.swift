import CoreGraphics
import CoreText
import Foundation
import Testing
@testable import Parallax
import ParallaxSubtitles

/// App-hosted: the source faces live in `ParallaxSubtitles`' resource bundle, which only
/// resolves inside a real app bundle.
@Suite("VLC subtitle fonts — name rewrite")
struct SFNTNameRewriteTests {

    private func latinSans() throws -> Data {
        let url = try #require(
            SubtitleFontBundle.fileURLs.first { $0.lastPathComponent == "NotoSans-Regular.ttf" }
        )
        return try Data(contentsOf: url)
    }

    @Test("the rewritten face reports the family VLC's libass asks for")
    func rewriteRenamesTheFamily() throws {
        let renamed = try SFNTNameRewrite.renamed(
            latinSans(), family: "Helvetica Neue", postScriptName: "Probe-Regular"
        )
        let names = try #require(SFNTNameTableReader.records(in: renamed))

        #expect(names[1] == "Helvetica Neue")   // family
        #expect(names[2] == "Regular")          // subfamily
        #expect(names[4] == "Helvetica Neue")   // full name
        #expect(names[6] == "Probe-Regular")    // PostScript
    }

    /// OFL 1.1 forbids distributing a modified face under the Reserved Font Name. The
    /// copy never leaves the device, but the name table is where the claim would live, so
    /// prove it carries no Noto string at all.
    @Test("no Reserved Font Name survives the rewrite")
    func rewriteDropsEveryNotoString() throws {
        let renamed = try SFNTNameRewrite.renamed(
            latinSans(),
            family: VLCSubtitleFonts.libassDefaultFamily,
            postScriptName: VLCSubtitleFonts.fallbackPostScriptName
        )
        let names = try #require(SFNTNameTableReader.records(in: renamed))

        #expect(names.isEmpty == false)
        #expect(names.values.contains { $0.localizedCaseInsensitiveContains("noto") } == false)
    }

    @Test("the rewritten bytes are still a font a rasterizer will open")
    func rewriteProducesAValidSFNT() throws {
        let renamed = try SFNTNameRewrite.renamed(
            latinSans(), family: "Helvetica Neue", postScriptName: "Probe-Regular"
        )
        let provider = try #require(CGDataProvider(data: renamed as CFData))
        let font = try #require(CGFont(provider))

        #expect(font.numberOfGlyphs > 100)
        // CoreText reads nameID 6; this is the rewrite proven through a real parser
        // rather than through our own reader.
        #expect((font.postScriptName as String?) == "Probe-Regular")
    }

    @Test("a non-sfnt payload is rejected rather than silently mangled")
    func rewriteRejectsGarbage() throws {
        #expect(throws: SFNTNameRewrite.Failure.self) {
            _ = try SFNTNameRewrite.renamed(
                Data(repeating: 0x21, count: 4096), family: "X", postScriptName: "X"
            )
        }
    }
}

@Suite("VLC subtitle fonts — directories")
struct VLCSubtitleFontsDirectoryTests {

    private func tempRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "vlc-fonts-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("each design gets every bundled face plus a face named for libass' default")
    func buildsBothDesigns() throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let built = VLCSubtitleFonts.buildDirectories(in: root)
        #expect(Set(built.keys) == Set(SubtitleFontBundle.Design.allCases))

        for (design, dir) in built {
            let names = try Set(FileManager.default
                .contentsOfDirectory(atPath: dir.path))
            let bundled = Set(SubtitleFontBundle.fileURLs.map(\.lastPathComponent))
            #expect(bundled.isSubset(of: names))
            #expect(names.contains(VLCSubtitleFonts.fallbackFileName))

            // The renamed face IS the design's Latin face — the whole point, since the
            // family is the only lever VLC leaves us.
            let renamed = try Data(contentsOf: dir.appending(path: VLCSubtitleFonts.fallbackFileName))
            let names2 = try #require(SFNTNameTableReader.records(in: renamed))
            #expect(names2[1] == VLCSubtitleFonts.libassDefaultFamily)

            let source = try #require(SubtitleFontBundle.fileURLs.first {
                $0.lastPathComponent == (design == .serif ? "NotoSerif-Regular.ttf" : "NotoSans-Regular.ttf")
            })
            let expected = try SFNTNameRewrite.renamed(
                Data(contentsOf: source),
                family: VLCSubtitleFonts.libassDefaultFamily,
                postScriptName: VLCSubtitleFonts.fallbackPostScriptName
            )
            #expect(renamed == expected)
        }
    }

    @Test("a completed directory is reused, not rebuilt")
    func completedDirectoryIsReused() throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let first = VLCSubtitleFonts.buildDirectories(in: root)
        let dir = try #require(first[.sans])
        // A rebuild wipes the directory, so a file only this test put there is the
        // evidence: if it survives, nothing was rebuilt.
        let sentinel = dir.appending(path: "sentinel.txt", directoryHint: .notDirectory)
        try Data("x".utf8).write(to: sentinel)

        let second = VLCSubtitleFonts.buildDirectories(in: root)

        #expect(second[.sans] == dir)
        #expect(FileManager.default.fileExists(atPath: sentinel.path))
    }

    @Test("previous builds' roots are dropped, the live one is kept")
    func stalePeersArePruned() throws {
        let parent = try tempRoot()
        defer { try? FileManager.default.removeItem(at: parent) }
        let live = parent.appending(path: "42-v1", directoryHint: .isDirectory)
        let stale = parent.appending(path: "41-v1", directoryHint: .isDirectory)
        for url in [live, stale] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }

        VLCSubtitleFonts.pruneStaleRoots(keeping: live)

        #expect(FileManager.default.fileExists(atPath: live.path))
        #expect(FileManager.default.fileExists(atPath: stale.path) == false)
    }

    @Test("the retired locator's cache is dropped once, and a second pass is a no-op")
    func retiredCacheIsPruned() throws {
        let caches = try tempRoot()
        defer { try? FileManager.default.removeItem(at: caches) }
        let orphan = caches.appending(
            path: VLCSubtitleFonts.retiredLocatorCacheName, directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: orphan, withIntermediateDirectories: true)
        try Data(repeating: 0, count: 32).write(to: orphan.appending(path: "system-ja-hn1.ttf"))

        #expect(VLCSubtitleFonts.pruneRetiredCaches(in: caches))
        #expect(FileManager.default.fileExists(atPath: orphan.path) == false)
        #expect(VLCSubtitleFonts.pruneRetiredCaches(in: caches) == false)
    }
}

/// An independent `name`-table reader, deliberately not sharing a line with the writer:
/// a shared parser would agree with a wrong writer.
enum SFNTNameTableReader {
    /// nameID → string, for the Microsoft-platform (3/1) records.
    static func records(in data: Data) -> [UInt16: String]? {
        let bytes = [UInt8](data)
        guard bytes.count > 12 else { return nil }
        func be16(_ i: Int) -> UInt16 { UInt16(bytes[i]) << 8 | UInt16(bytes[i + 1]) }
        func be32(_ i: Int) -> UInt32 {
            UInt32(bytes[i]) << 24 | UInt32(bytes[i + 1]) << 16
                | UInt32(bytes[i + 2]) << 8 | UInt32(bytes[i + 3])
        }
        var table: Range<Int>?
        for i in 0..<Int(be16(4)) {
            let entry = 12 + 16 * i
            guard entry + 16 <= bytes.count else { return nil }
            if be32(entry) == 0x6E61_6D65 {
                let offset = Int(be32(entry + 8)), length = Int(be32(entry + 12))
                guard offset + length <= bytes.count else { return nil }
                table = offset..<(offset + length)
            }
        }
        guard let table else { return nil }
        let base = table.lowerBound
        let count = Int(be16(base + 2))
        let storage = base + Int(be16(base + 4))
        var out: [UInt16: String] = [:]
        for i in 0..<count {
            let record = base + 6 + 12 * i
            guard record + 12 <= table.upperBound else { return nil }
            guard be16(record) == 3, be16(record + 2) == 1 else { continue }
            let nameID = be16(record + 6)
            let length = Int(be16(record + 8)), offset = Int(be16(record + 10))
            let start = storage + offset
            guard start + length <= bytes.count else { return nil }
            let units = stride(from: start, to: start + length, by: 2).map {
                UInt16(bytes[$0]) << 8 | UInt16(bytes[$0 + 1])
            }
            out[nameID] = String(decoding: units, as: UTF16.self)
        }
        return out
    }
}
