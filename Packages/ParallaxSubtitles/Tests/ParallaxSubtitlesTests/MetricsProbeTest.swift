import CoreGraphics
import Foundation
import Testing
@testable import ParallaxSubtitles

/// Synthesized-subset metrics must land in the same scale regime as real system
/// fonts — a malformed table (the OS/2 field-count bug this guards against)
/// renders glyphs at a garbage multiple of the style size, which no glyph-level
/// check can see.
@Suite("Synthesized font metrics")
struct MetricsProbeTest {
    @Test("subset renders at system-font scale, not a multiple of it")
    func subsetMatchesSystemScale() async throws {
        // Han goes through the synthesized PingFang subset…
        let han = await makeProbeRenderer()
        try await han.load(Data("1\n00:00:01,000 --> 00:00:03,000\n字字字字\n".utf8), format: .srt)
        let hanRect = try #require(await han.frame(at: 2.0)).imageRect

        // …kana through Hiragino's real, FreeType-readable file.
        let kana = await makeProbeRenderer()
        try await kana.load(Data("1\n00:00:01,000 --> 00:00:03,000\nああああ\n".utf8), format: .srt)
        let kanaRect = try #require(await kana.frame(at: 2.0)).imageRect

        // Both are 4 full-width CJK cells at the same style size; anything
        // beyond ±25% is a broken table, not a design difference.
        #expect(abs(hanRect.width - kanaRect.width) / kanaRect.width < 0.25)
        #expect(abs(hanRect.height - kanaRect.height) / kanaRect.height < 0.25)
    }
}
