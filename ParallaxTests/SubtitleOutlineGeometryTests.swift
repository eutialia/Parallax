import Testing
import ParallaxPlayback
import ParallaxSubtitles

/// The canonical ring is one static on `SubtitleStyle`; the synthesized ASS script
/// carries the same width in its style line so a converted cue has the look before
/// the override lands. The two packages cannot import each other, so this is the
/// only place the numbers meet. A retune of one that leaves the other behind fails
/// here instead of on the first frame of every external SRT.
@Suite struct SubtitleOutlineGeometryTests {

    @Test("the synthesized script's ring is the canonical ratio of the em")
    func outlineAgrees() {
        #expect(SubtitleRenderer.convertedScriptOutlineEmRatio == SubtitleStyle.outlineWidthRatio)
    }
}
