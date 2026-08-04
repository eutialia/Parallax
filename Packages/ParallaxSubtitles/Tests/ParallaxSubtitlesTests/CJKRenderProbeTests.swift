import CoreGraphics
import CoreText
import Foundation
import Testing

@testable import ParallaxSubtitles

/// CJK glyph coverage through the full render path. Tofu is a *successful*
/// render of .notdef boxes, so pixels alone can't catch it — libass' captured
/// font-selection log is the assertion surface: a glyph nobody could supply
/// logs "failed to find any fallback".
///
/// Why synthesis exists: CoreText's fallback answer for Chinese ideographs is
/// PingFang, whose outlines live in Apple's proprietary `hvgl` table (no
/// glyf/CFF — verified) that FreeType cannot read. `SystemGlyphFont` rebuilds
/// the needed system glyphs into a per-track TrueType subset so libass renders
/// the SAME design the OS would — no bundled font. Without it, any cue whose
/// FIRST missing glyph was Han died wholesale (the 2026-08-04 device report:
/// Japanese fine, Chinese partially or fully tofu).
@Suite("CJK render fallback")
struct CJKRenderProbeTests {

    /// Han-FIRST text is the poison case — its CoreText fallback is PingFang.
    private static let hanFirstSRT = """
    1
    00:00:01,000 --> 00:00:03,000
    這是繁體中文字幕測試
    简体字幕测试

    """

    @Test("PingFang's file is (still) FreeType-unreadable; Hiragino's is readable")
    func readabilityDiscriminates() throws {
        let pingfang = CTFontCreateWithName("PingFangSC-Regular" as CFString, 24, nil)
        let hiragino = CTFontCreateWithName("HiraginoSans-W4" as CFString, 24, nil)
        let pfURL = try #require(CTFontCopyAttribute(pingfang, kCTFontURLAttribute) as? URL)
        let hgURL = try #require(CTFontCopyAttribute(hiragino, kCTFontURLAttribute) as? URL)
        // If this ever flips, Apple changed formats again — revisit SystemGlyphFont.
        #expect(!SystemGlyphFont.fileIsFreeTypeReadable(pfURL))
        #expect(SystemGlyphFont.fileIsFreeTypeReadable(hgURL))
    }

    @Test("subset synthesis produces a self-readable font under the source family name")
    func subsetRoundTrips() throws {
        let scalars = Array("這是繁體字幕測試简体测试".unicodeScalars)
        let pingfang = CTFontCreateWithName("PingFangSC-Regular" as CFString, 24, nil)
        let data = try #require(SystemGlyphFont.subsetFont(scalars: scalars, from: pingfang))

        // The subset must clear the same readability bar system files are held to.
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pf-subset.ttf")
        try data.write(to: url)
        #expect(SystemGlyphFont.fileIsFreeTypeReadable(url))
        print("CJKPROBE subset: \(data.count) bytes at \(url.path)")

        // And CoreText itself must accept it — a stronger structural check than
        // our own directory parse (cmap, glyf and metrics all get validated).
        let provider = try #require(CGDataProvider(data: data as CFData))
        let cgFont = try #require(CGFont(provider))
        #expect(cgFont.numberOfGlyphs == Set(scalars.map { String(String.UnicodeScalarView([$0])) }).count + 1
                || cgFont.numberOfGlyphs > 1)
        let ctFont = CTFontCreateWithGraphicsFont(cgFont, 24, nil, nil)
        var chars = Array("字".utf16)
        var glyphs = [CGGlyph](repeating: 0, count: chars.count)
        #expect(CTFontGetGlyphsForCharacters(ctFont, &chars, &glyphs, chars.count))
        #expect(glyphs[0] != 0)
        let path = CTFontCreatePathForGlyph(ctFont, glyphs[0], nil)
        #expect(path != nil && path?.boundingBoxOfPath.isEmpty == false)
    }

    @Test("Chinese-first SRT renders through synthesized system glyphs, no dead glyphs")
    func chineseFirstSRTRendersViaSynthesis() async throws {
        let renderer = await makeProbeRenderer()
        try await renderer.load(Data(Self.hanFirstSRT.utf8), format: .srt)
        let frame = try #require(await renderer.frame(at: 2.0))
        _ = try #require(frame.image)
        #expect(try opaqueFraction(of: frame) > 0)

        let log = await renderer.diagnosticLog
        #expect(!log.contains { $0.contains("failed to find any fallback") })
    }

    @Test("authored ASS with an uninstalled fansub font still covers Han glyphs")
    func authoredASSWithFansubFontCoversHan() async throws {
        let renderer = await makeProbeRenderer()
        let script = ASSFixture.script(text: "字幕測試 简体测试")
            .replacingOccurrences(of: "Style: Default,Helvetica Neue",
                                  with: "Style: Default,方正准圆_GBK")
        try await renderer.load(Data(script.utf8), format: .ass)
        let frame = try #require(await renderer.frame(at: 2.0))
        _ = try #require(frame.image)

        let log = await renderer.diagnosticLog
        #expect(!log.contains { $0.contains("failed to find any fallback") })
    }
}
