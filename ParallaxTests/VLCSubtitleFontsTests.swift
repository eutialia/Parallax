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

    private func bundled(_ name: String) throws -> URL {
        try #require(SubtitleFontBundle.fileURLs.first { $0.lastPathComponent == name })
    }

    /// The rewrite is only provable through a parser that reads a FILE, so every
    /// collection assertion goes through one of these.
    private func materialized(_ data: Data, as name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "\(UUID().uuidString)-\(name)", directoryHint: .notDirectory)
        try data.write(to: url)
        return url
    }

    private func renamedSansCJK() throws -> (source: URL, index: Int, data: Data) {
        let source = try bundled("NotoSansCJK-Regular.ttc")
        let index = try #require(
            SubtitleFontBundle.faceFamilyNames(in: source).firstIndex(of: "Noto Sans CJK SC")
        )
        let data = try SFNTNameRewrite.renamed(
            Data(contentsOf: source, options: .mappedIfSafe),
            faceIndex: index,
            family: VLCSubtitleFonts.libassDefaultFamily,
            postScriptName: VLCSubtitleFonts.fallbackPostScriptName
        )
        return (source, index, data)
    }

    /// The whole point of the face-indexed rewrite: one face of a ten-face collection
    /// answers to VLC's default family, and the other nine still answer to their own
    /// names — they are unmodified bytes, licence and all.
    @Test("exactly one face of the collection is renamed")
    func rewriteRenamesOneFaceAndLeavesTheRest() throws {
        let (source, index, data) = try renamedSansCJK()
        let written = try materialized(data, as: "NotoSansCJK-Regular.ttc")
        defer { try? FileManager.default.removeItem(at: written) }

        var expected = SubtitleFontBundle.faceFamilyNames(in: source)
        expected[index] = VLCSubtitleFonts.libassDefaultFamily

        #expect(SubtitleFontBundle.faceFamilyNames(in: written) == expected)
    }

    /// OFL 1.1 forbids distributing a modified face under the Reserved Font Name. The
    /// copy never leaves the device, but the name table is where the claim would live, so
    /// prove the rewritten face carries no Noto string at all.
    @Test("the renamed face carries the records libass reads and no Reserved Font Name")
    func rewriteDropsEveryNotoStringOnTheRenamedFace() throws {
        let (_, index, data) = try renamedSansCJK()
        let names = try #require(SFNTNameTableReader.records(in: data, faceIndex: index))

        #expect(names[1] == VLCSubtitleFonts.libassDefaultFamily)  // family
        #expect(names[2] == "Regular")                             // subfamily
        #expect(names[4] == VLCSubtitleFonts.libassDefaultFamily)  // full name
        #expect(names[6] == VLCSubtitleFonts.fallbackPostScriptName)
        #expect(names.values.contains { $0.localizedCaseInsensitiveContains("noto") } == false)
    }

    /// Our own reader would agree with a wrong writer. CoreText is the independent
    /// parser: it has to see BOTH the renamed face and the untouched ones in the same
    /// file, which is what proves the appended table and the patched directory record
    /// left the collection intact.
    @Test("the rewritten collection is still a collection CoreText opens")
    func rewriteProducesACollectionCoreTextOpens() throws {
        let (_, _, data) = try renamedSansCJK()
        let written = try materialized(data, as: "NotoSansCJK-Regular.ttc")
        defer { try? FileManager.default.removeItem(at: written) }

        let descriptors = try #require(
            CTFontManagerCreateFontDescriptorsFromURL(written as CFURL) as? [CTFontDescriptor]
        )
        let families = descriptors.compactMap {
            CTFontDescriptorCopyAttribute($0, kCTFontFamilyNameAttribute) as? String
        }

        #expect(families.contains(VLCSubtitleFonts.libassDefaultFamily))
        #expect(families.contains("Noto Sans CJK JP"))
        #expect(families.contains("Noto Sans CJK SC") == false)
    }

    /// A single sfnt is a collection of one — same code, no special case. Nothing in the
    /// app renames a Latin face any more, but the generalization is only honest if the
    /// degenerate arity works.
    @Test("a single-face sfnt renames through the same path")
    func rewriteRenamesASingleFaceFile() throws {
        let source = try bundled("NotoSans-Regular.ttf")
        let renamed = try SFNTNameRewrite.renamed(
            Data(contentsOf: source), family: "Helvetica Neue", postScriptName: "Probe-Regular"
        )
        let written = try materialized(renamed, as: "Probe-Regular.ttf")
        defer { try? FileManager.default.removeItem(at: written) }

        #expect(SubtitleFontBundle.faceFamilyNames(in: written) == ["Helvetica Neue"])
        let provider = try #require(CGDataProvider(data: renamed as CFData))
        let font = try #require(CGFont(provider))
        #expect(font.numberOfGlyphs > 100)
        #expect((font.postScriptName as String?) == "Probe-Regular")
    }

    @Test("a non-sfnt payload is rejected rather than silently mangled")
    func rewriteRejectsGarbage() throws {
        #expect(throws: SFNTNameRewrite.Failure.notAnSFNT) {
            _ = try SFNTNameRewrite.renamed(
                Data(repeating: 0x21, count: 4096), family: "X", postScriptName: "X"
            )
        }
    }

    @Test("a face index the file does not have is refused")
    func rewriteRejectsAMissingFace() throws {
        let source = try bundled("NotoSans-Regular.ttf")
        #expect(throws: SFNTNameRewrite.Failure.noSuchFace) {
            _ = try SFNTNameRewrite.renamed(
                Data(contentsOf: source), faceIndex: 1, family: "X", postScriptName: "X"
            )
        }
    }
}

@Suite("VLC subtitle fonts — fallback region")
struct VLCSubtitleFallbackRegionTests {

    /// The face answering to `default_family` has to draw ONE region's Han shapes, and
    /// nothing about the media says which before a cue is parsed — so the device's own
    /// language order decides, first CJK hit wins, Japanese when there is none.
    @Test(
        "the first CJK language in the device's list picks the face",
        arguments: [
            (["en-CA", "zh-Hans-CA"], CJKFontPlan.Language.simplifiedChinese),
            (["zh-TW"], CJKFontPlan.Language.traditionalChinese),
            (["ja"], CJKFontPlan.Language.japanese),
            (["ko-KR"], CJKFontPlan.Language.korean),
            (["en", "fr"], CJKFontPlan.Language.japanese),
            ([], CJKFontPlan.Language.japanese),
        ]
    )
    func regionFollowsPreferredLanguages(
        languages: [String], expected: CJKFontPlan.Language
    ) {
        #expect(VLCSubtitleFonts.fallbackLanguage(preferredLanguages: languages) == expected)
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

    private func fileType(_ url: URL) throws -> FileAttributeType? {
        // `attributesOfItem` lstats — a symlink reports as one instead of as its target,
        // which is the whole distinction under test.
        try FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType
    }

    private func size(of url: URL) throws -> Int {
        try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int ?? 0
    }

    /// The layout in one assertion: the bundle's files and NOTHING else (no synthesized
    /// Latin fallback any more), the design's own CJK collection materialized as a real
    /// file with its regional face renamed, everything else a link into the app bundle.
    @Test("each design links the bundle and copies its own CJK collection, renamed")
    func buildsBothDesigns() throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let built = VLCSubtitleFonts.buildDirectories(in: root, language: .simplifiedChinese)
        #expect(Set(built.keys) == Set(SubtitleFontBundle.Design.allCases))

        for (design, dir) in built {
            let bundled = Set(SubtitleFontBundle.fileURLs.map(\.lastPathComponent))
            let present = try Set(FileManager.default.contentsOfDirectory(atPath: dir.path))
            #expect(present == bundled)

            let collection = design == .serif ? "NotoSerifCJK-Regular.ttc" : "NotoSansCJK-Regular.ttc"
            for name in bundled {
                let expected: FileAttributeType = name == collection ? .typeRegular : .typeSymbolicLink
                let type = try fileType(dir.appending(path: name))
                #expect(type == expected, "\(name)")
            }

            // Appended, not reassembled: the copy is the source plus one small `name`
            // table, so the 20 MB of shared glyph data was never rebuilt.
            let source = try #require(
                SubtitleFontBundle.fileURLs.first { $0.lastPathComponent == collection }
            )
            let grew = try size(of: dir.appending(path: collection)) - size(of: source)
            #expect(grew > 0 && grew < 1_024, "grew by \(grew) bytes")

            let families = SubtitleFontBundle.faceFamilyNames(in: dir.appending(path: collection))
            #expect(families.contains(VLCSubtitleFonts.libassDefaultFamily))
            #expect(families.contains(design == .serif ? "Noto Serif CJK SC" : "Noto Sans CJK SC") == false)
            // The regions we did NOT pick are still reachable under their own names.
            #expect(families.contains(design == .serif ? "Noto Serif CJK JP" : "Noto Sans CJK JP"))

            let marker = root.appending(path: ".\(design.rawValue)-complete")
            #expect(FileManager.default.fileExists(atPath: marker.path))
        }
    }

    @Test("a completed directory is reused, not rebuilt")
    func completedDirectoryIsReused() throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let first = VLCSubtitleFonts.buildDirectories(in: root, language: .japanese)
        let dir = try #require(first[.sans])
        // A rebuild wipes the directory, so a file only this test put there is the
        // evidence: if it survives, nothing was rebuilt.
        let sentinel = dir.appending(path: "sentinel.txt", directoryHint: .notDirectory)
        try Data("x".utf8).write(to: sentinel)

        let second = VLCSubtitleFonts.buildDirectories(in: root, language: .japanese)

        #expect(second[.sans] == dir)
        #expect(FileManager.default.fileExists(atPath: sentinel.path))
    }

    @Test("previous builds' roots are dropped, the live one is kept")
    func stalePeersArePruned() throws {
        let parent = try tempRoot()
        defer { try? FileManager.default.removeItem(at: parent) }
        let live = parent.appending(path: "42-v2-zh-Hans", directoryHint: .isDirectory)
        let stale = parent.appending(path: "42-v2-ja", directoryHint: .isDirectory)
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
    /// nameID → string, for the Microsoft-platform (3/1) records of one face.
    static func records(in data: Data, faceIndex: Int = 0) -> [UInt16: String]? {
        let bytes = [UInt8](data)
        guard bytes.count > 12 else { return nil }
        func be16(_ i: Int) -> UInt16 { UInt16(bytes[i]) << 8 | UInt16(bytes[i + 1]) }
        func be32(_ i: Int) -> UInt32 {
            UInt32(bytes[i]) << 24 | UInt32(bytes[i + 1]) << 16
                | UInt32(bytes[i + 2]) << 8 | UInt32(bytes[i + 3])
        }
        let face: Int
        if be32(0) == 0x7474_6366 {  // 'ttcf'
            guard faceIndex < Int(be32(8)), 12 + 4 * faceIndex + 4 <= bytes.count else { return nil }
            face = Int(be32(12 + 4 * faceIndex))
        } else {
            guard faceIndex == 0 else { return nil }
            face = 0
        }
        var table: Range<Int>?
        for i in 0..<Int(be16(face + 4)) {
            let entry = face + 12 + 16 * i
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
