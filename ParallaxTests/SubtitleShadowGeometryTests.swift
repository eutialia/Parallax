import Testing
import ParallaxPlayback
import ParallaxSubtitles

/// The canonical shadow is three statics on `SubtitleStyle`; the synthesized ASS
/// script carries the offset and opacity again in its style line so a converted cue
/// has the look before the override lands. The two packages cannot import each
/// other, so this is the only place the numbers meet. A retune of one that leaves the
/// other behind fails here instead of on the first frame of every external SRT.
@Suite struct SubtitleShadowGeometryTests {

    @Test("the synthesized script's shadow offset is the canonical ratio of the em")
    func offsetAgrees() {
        #expect(SubtitleRenderer.convertedScriptShadowEmRatio == SubtitleStyle.shadowOffsetRatio)
    }

    @Test("the synthesized script's shadow opacity is the canonical opacity")
    func opacityAgrees() {
        #expect(SubtitleRenderer.convertedScriptShadowAlpha == SubtitleStyle.shadowOpacity)
    }
}
