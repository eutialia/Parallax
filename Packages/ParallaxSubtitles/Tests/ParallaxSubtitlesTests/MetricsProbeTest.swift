import CoreGraphics
import Foundation
import Testing

@testable import ParallaxSubtitles

/// libass sizes every face VSFilter-style from the OS/2 win box, so
/// the app-side scale mapping is only correct if the numbers it divides by are
/// the shipped files' own. These read them out of the bundle and pin them.
@Suite("Bundled font metrics")
struct MetricsProbeTest {

    @Test("every face of a collection declares one em box, read from the file")
    func collectionsAgreeOnTheirEmBox() throws {
        // A per-face difference would make a converted cue need \\fs
        // compensation BETWEEN its own regions — the tagger would emit it, but
        // the app-side scale mapping (which only knows the style family) could
        // not follow.
        for (file, expected) in [
            ("NotoSansCJK-Regular.ttc", 1.448), ("NotoSerifCJK-Regular.ttc", 1.437),
        ] {
            let url = SubtitleFontBundle.directoryURL.appending(path: file)
            let faces = SFNTFace.faces(of: url)
            #expect(!faces.isEmpty)
            for face in faces {
                #expect(face.metrics.unitsPerEm == 1000)
                let box = (Double(face.metrics.winAscent) + Double(face.metrics.winDescent))
                    / Double(face.metrics.unitsPerEm)
                #expect(abs(box - expected) < 0.001, "\(face.familyName) box \(box)")
                #expect(abs(SubtitleFontMetrics.emBoxFactor(forFamily: face.familyName) - expected)
                    < 0.001)
            }
        }
    }

    /// Every bundled family must have a real box, because the tagger divides by
    /// it: a family that silently answered 1 would render a script at the wrong
    /// size with nothing in the log. The spread is wide — 1.24 to 2.50 — which
    /// is exactly why the \\fs compensation is not decorative.
    @Test("every routed family has a real em box, and they are not all the same")
    func everyRoutedFamilyHasAnEmBox() {
        var factors: Set<Double> = []
        for script in SubtitleFontBundle.Script.allCases {
            for design in SubtitleFontBundle.Design.allCases {
                let family = SubtitleFontBundle.family(design: design, script: script)
                let factor = SubtitleFontMetrics.emBoxFactor(forFamily: family)
                #expect(factor > 1.1 && factor < 2.6, "\(family) box \(factor)")
                factors.insert(factor)
            }
        }
        #expect(factors.count > 10)
    }

    @Test("the file\'s vertical metrics are read, not invented")
    func readsRealVerticalMetrics() throws {
        let metrics = try #require(SubtitleFontBundle.metrics(forFamily: "Noto Sans CJK SC"))
        #expect(metrics.unitsPerEm == 1000)
        #expect(metrics.winAscent == 1160)
        #expect(metrics.winDescent == 288)
    }

    @Test("a family the bundle does not carry has no metrics and no factor")
    func unknownFamiliesAreHonest() {
        #expect(SubtitleFontBundle.metrics(forFamily: "PingFang SC") == nil)
        #expect(SubtitleFontMetrics.emBoxFactor(forFamily: "PingFang SC") == 1)
    }

    /// The two designs do NOT render at the same size, and must not be forced
    /// to: Noto Sans declares a 1.519 em box and Noto Serif 1.458, and libass
    /// divides the requested size by it. What has to hold is that the ratio is
    /// exactly that — the app-side scale mapping multiplies the style family's
    /// factor back in, so any OTHER difference would be an uncompensated one a
    /// user sees as the caption resizing when they switch design.
    /// Measured on a 2560x1440 canvas rather than the 640x360 probe one, and the
    /// reason is arithmetic: the claim is a 4.2% difference (1.519/1.458), and a
    /// ±1 px quantisation of a 24 px glyph is ±4% — noise the size of the whole
    /// signal. At 4x the canvas the same quantisation is ±1%, which is what lets
    /// the tolerance be 0.01, a quarter of the effect being measured.
    ///
    /// On the advance WIDTH of four glyphs, not their ink height: how tall the
    /// ink of 字 sits inside its em is a property of each face's drawing (the
    /// serif CJK face's is ~4% shorter than the sans one's at the same size, and
    /// both measure 82 px on this canvas), so height cannot separate a scale
    /// difference from a design difference. Advance width can.
    @Test("the two designs differ in scale by exactly their em-box ratio")
    func designsMatchInScale() async throws {
        func inkExtent(family: String) async throws -> CGRect {
            let renderer = SubtitleRenderer(defaultFontFamily: family)
            await renderer.setCanvas(
                size: CGSize(width: 2560, height: 1440), scale: 1,
                storageSize: CGSize(width: 2560, height: 1440)
            )
            try await renderer.load(SRTFixture.data(text: "字字字字"), format: .srt)
            return try #require(await renderer.frame(at: 2.0)).imageRect
        }

        let sansRect = try await inkExtent(family: SubtitleFontBundle.sansFamily)
        let serifRect = try await inkExtent(family: SubtitleFontBundle.serifFamily)

        let expected = SubtitleFontMetrics.emBoxFactor(forFamily: SubtitleFontBundle.sansFamily)
            / SubtitleFontMetrics.emBoxFactor(forFamily: SubtitleFontBundle.serifFamily)
        #expect(abs(expected - 1.519 / 1.458) < 0.001)
        #expect(abs(serifRect.width / sansRect.width - expected) < 0.01, "\(serifRect) \(sansRect)")
    }
}
