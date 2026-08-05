import CoreGraphics
import CoreText
import Foundation
import Testing
@testable import ParallaxSubtitles

/// Synthesized-subset metrics must be the SOURCE font's metrics, verbatim.
/// libass sizes and baselines every font VSFilter-style from OS/2 and hhea, so
/// invented values render CJK at the wrong scale relative to Latin in the same
/// line (the "Latin sits higher" device report), and a misaligned table (the
/// OS/2 field-count bug) explodes the scale outright — neither is visible to
/// any glyph-level check.
@Suite("Synthesized font metrics")
struct MetricsProbeTest {

    @Test("subset carries the source file's vertical metrics, ratio-exact")
    func subsetCopiesRealMetrics() throws {
        let pingfang = CTFontCreateWithName(pingFangSCRegular as CFString, 24, nil)
        let sourceURL = try #require(CTFontCopyAttribute(pingfang, kCTFontURLAttribute) as? URL)
        let source = try #require(SystemGlyphFont.faceMetrics(of: sourceURL))

        let data = try #require(SystemGlyphFont.subsetFont(
            scalars: Array("字幕测试".unicodeScalars), from: pingfang
        ))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pf-metrics.ttf")
        try data.write(to: url)
        let subset = try #require(SystemGlyphFont.faceMetrics(of: url))

        // CoreText serves the hvgl faces on its own unit grid (1000 against the
        // file's declared 1028), and the extracted outlines live in that grid —
        // so the copied metrics are rescaled, and it's the per-em RATIOS that
        // must survive exactly. Those ratios are all libass' VSFilter-style
        // sizing ever reads.
        func ratio(_ value: some BinaryInteger, of metrics: SystemGlyphFont.FaceMetrics) -> Double {
            Double(value) / Double(metrics.unitsPerEm)
        }
        let pairs: [(Double, Double)] = [
            (ratio(subset.hheaAscender, of: subset), ratio(source.hheaAscender, of: source)),
            (ratio(subset.hheaDescender, of: subset), ratio(source.hheaDescender, of: source)),
            (ratio(subset.hheaLineGap, of: subset), ratio(source.hheaLineGap, of: source)),
            (ratio(subset.typoAscender, of: subset), ratio(source.typoAscender, of: source)),
            (ratio(subset.typoDescender, of: subset), ratio(source.typoDescender, of: source)),
            (ratio(subset.typoLineGap, of: subset), ratio(source.typoLineGap, of: source)),
            (ratio(subset.winAscent, of: subset), ratio(source.winAscent, of: source)),
            (ratio(subset.winDescent, of: subset), ratio(source.winDescent, of: source)),
        ]
        for (synthesized, real) in pairs {
            #expect(abs(synthesized - real) < 0.002)
        }
        // The real PingFang usWin box is famously tall (~1.36 em) — if this
        // reads ~1.0, the copy silently fell back to invented metrics again.
        #expect(ratio(subset.winAscent, of: subset) + ratio(subset.winDescent, of: subset) > 1.2)
    }

    @Test("subset renders at system-font scale, not a multiple of it")
    func subsetMatchesSystemScale() async throws {
        // Han goes through the synthesized PingFang subset…
        let han = await makeProbeRenderer()
        try await han.load(SRTFixture.data(text: "字字字字"), format: .srt)
        let hanRect = try #require(await han.frame(at: 2.0)).imageRect

        // …kana through Hiragino's real, FreeType-readable file.
        let kana = await makeProbeRenderer()
        try await kana.load(SRTFixture.data(text: "ああああ"), format: .srt)
        let kanaRect = try #require(await kana.frame(at: 2.0)).imageRect

        // Both are 4 full-width CJK cells at the same style size. With real
        // metrics the two families legitimately normalize differently (PingFang
        // declares a taller usWin box than Hiragino), so parity is bounded, not
        // exact; a broken table overshoots this by whole multiples.
        #expect(abs(hanRect.width - kanaRect.width) / kanaRect.width < 0.35)
        #expect(abs(hanRect.height - kanaRect.height) / kanaRect.height < 0.35)
    }
}
