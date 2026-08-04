import CoreGraphics
import Foundation
import Testing

@testable import ParallaxSubtitles

/// CJK glyph coverage through the full render path. Tofu is a *successful*
/// render of .notdef boxes, so pixels alone can't catch it — libass' captured
/// font-selection log is the assertion surface: a glyph nobody could supply
/// logs "failed to find any fallback", and a rescue by the bundled font logs
/// "Using default font".
///
/// Why the bundled font must exist at all: CoreText's fallback answer for
/// Chinese ideographs is PingFang, whose modern container FreeType cannot
/// parse ("loca table missing", verified against FreeType 2.13) — so without
/// a bundled face, any cue whose FIRST missing glyph is Han dies wholesale,
/// while kana-first cues luck into Hiragino and mostly render. That was the
/// 2026-08-04 device report: Japanese fine, Chinese partially or fully tofu.
@Suite("CJK render fallback")
struct CJKRenderProbeTests {

    /// Han-FIRST text is the poison case — its CoreText fallback is PingFang.
    private static let hanFirstSRT = """
    1
    00:00:01,000 --> 00:00:03,000
    這是繁體中文字幕測試
    简体字幕测试

    """

    @Test("bundled font ships in the package bundle")
    func bundledFontExists() throws {
        let url = try #require(SubtitleFallbackFont.bundledURL)
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test("Chinese-first SRT renders through the bundled fallback, no dead glyphs")
    func chineseFirstSRTFallsBackToBundledFont() async throws {
        let renderer = await makeProbeRenderer()
        try await renderer.load(Data(Self.hanFirstSRT.utf8), format: .srt)
        let frame = try #require(await renderer.frame(at: 2.0))
        _ = try #require(frame.image)
        #expect(try opaqueFraction(of: frame) > 0)

        let log = await renderer.diagnosticLog
        #expect(!log.contains { $0.contains("failed to find any fallback") })
        #expect(log.contains { $0.contains("Using default font:") })
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
