import Testing
import ParallaxCore
import ParallaxPlayback
import ParallaxPlaybackTestSupport

@Suite("PlayableAsset — libvlc instance arguments")
struct VLCInstanceArgumentsTests {

    /// The fix. The freetype renderer belongs to the video output, so its whole option set has
    /// to arrive as libvlc instance arguments — `--`, not `:`. `.opaqueBox` is the other half
    /// of the user's background choice: box on, ring off.
    @Test("the font family and the style become the `--freetype-*` argument set",
          arguments: [SubtitleBackground.outline, .opaqueBox])
    func freetypeArgumentsCarryTheAssetStyle(background: SubtitleBackground) {
        let boxed = background == .opaqueBox
        let style = SubtitleStyle.standard.with { $0.background = background }
        let options = PlayableAsset.fixture(
            subtitleFontFamily: "Noto Sans CJK SC",
            subtitleTextStyle: EngineSubtitleTextStyle(style: style, relativeFontSize: 20)
        ).vlcInstanceArguments

        #expect(options == [
            "--freetype-font=Noto Sans CJK SC",
            // em = output height / 20 — the divisor the app computed from its own cue size.
            "--freetype-rel-fontsize=20",
            // Sans keeps freetype's own weight; the serif design asks for bold.
            "--no-freetype-bold",
            // 0.92 white, fully opaque.
            "--freetype-color=15461355",     // 0xEBEBEB
            "--freetype-opacity=255",
            // The canonical ring: opaque black, and 4 is a whole percent of the font
            // size — not one of the None/Thin/Normal/Thick presets its labels suggest.
            // Thickness is the only knob, so the opacity stays 255 for the box too.
            "--freetype-outline-color=0",
            "--freetype-outline-opacity=255",
            "--freetype-outline-thickness=\(boxed ? 0 : 4)",
            // No shadow on any renderer.
            "--freetype-shadow-opacity=0",
            "--freetype-shadow-distance=0",
            "--freetype-background-color=0",
            "--freetype-background-opacity=\(boxed ? 255 : 0)",
        ])
    }

    /// The serif design is weight 600 everywhere. freetype has no bold file to select
    /// from the bundle, so `freetype-bold` is the request to embolden synthetically —
    /// the VLC-side half of the client renderer's per-run `\b1`.
    /// The sans side is pinned by the full-array test above.
    @Test("the serif design asks freetype for bold")
    func serifDesignAsksForBold() {
        let style = SubtitleStyle.standard.with { $0.fontDesign = .serif }
        let options = PlayableAsset.fixture(
            subtitleFontFamily: "Noto Serif CJK JP",
            subtitleTextStyle: EngineSubtitleTextStyle(style: style, relativeFontSize: 20)
        ).vlcInstanceArguments
        #expect(options?.contains("--freetype-bold") == true, "\(options ?? [])")
        // libvlc takes the last spelling it sees, so the negative must be absent too.
        #expect(options?.contains("--no-freetype-bold") == false)
    }

    /// The pre-existing instance arguments (the timing-repair vout flags) keep their place at
    /// the head — they were always instance-scoped; the subtitle look simply joined them.
    @Test("caller library options pass through, ahead of the subtitle set")
    func callerLibraryOptionsComeFirst() {
        let options = PlayableAsset.fixture(
            subtitleFontFamily: "Noto Sans CJK SC",
            vlcLibraryOptions: ["--no-drop-late-frames", "--no-skip-frames"]
        ).vlcInstanceArguments
        #expect(options == [
            "--no-drop-late-frames", "--no-skip-frames", "--freetype-font=Noto Sans CJK SC",
        ])
    }

    /// Nothing to say → nil, which is what keeps a bare asset on the shared `VLCLibrary`
    /// instead of minting a private one that differs from it in nothing.
    @Test("nil when the asset carries no family, no style and no library options")
    func nilWhenTheAssetCarriesNothing() {
        #expect(PlayableAsset.fixture().vlcInstanceArguments == nil)
    }
}
