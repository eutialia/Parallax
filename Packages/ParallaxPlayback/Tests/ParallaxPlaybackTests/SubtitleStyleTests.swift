import Foundation
import Testing
import ParallaxPlayback

@Suite("SubtitleStyle.RGBA")
struct SubtitleRGBATests {

    /// `rgb24` is the integer form of VLC's `freetype-color` option — the one place the
    /// package's primitive colour crosses into libvlc, where a wrong shift or a dropped
    /// rounding silently recolours every embedded SRT.
    @Test("rgb24 packs the rounded 8-bit channels and drops alpha", arguments: [
        (1.0, 1.0, 1.0, 0xFFFFFF),
        (0.0, 0.0, 0.0, 0x000000),
        (1.0, 0.0, 0.0, 0xFF0000),
        (0.0, 1.0, 0.0, 0x00FF00),
        (0.0, 0.0, 1.0, 0x0000FF),
        (0.92, 0.92, 0.92, 0xEBEBEB),   // the standard fill: round(0.92 × 255) == 235
    ] as [(Double, Double, Double, Int)])
    func rgb24Packing(red: Double, green: Double, blue: Double, expected: Int) {
        #expect(SubtitleStyle.RGBA(red: red, green: green, blue: blue).rgb24 == expected)
    }

    @Test("alpha never reaches rgb24", arguments: [0.0, 0.25, 1.0])
    func alphaIsDropped(alpha: Double) {
        let colour = SubtitleStyle.RGBA(red: 1, green: 0.5, blue: 0, alpha: alpha)
        #expect(colour.rgb24 == SubtitleStyle.RGBA(red: 1, green: 0.5, blue: 0).rgb24)
    }

    @Test("alpha defaults to fully opaque")
    func alphaDefaultsToOpaque() {
        #expect(SubtitleStyle.RGBA(red: 0, green: 0, blue: 0).alpha == 1)
    }
}

@Suite("SubtitleStyle.standard")
struct SubtitleStyleStandardTests {

    /// Boxless by design, and deliberately below peak white so cues don't read as the
    /// brightest object in a tone-mapped HDR frame. These are the authored values every
    /// renderer (overlay, AVKit, VLC freetype) reads.
    @Test("the canonical look is 92% white in an opaque black border")
    func canonicalLook() {
        let s = SubtitleStyle.standard
        #expect(s.foreground.red == 0.92)
        #expect(s.foreground.green == 0.92)
        #expect(s.foreground.blue == 0.92)
        #expect(s.foreground.alpha == 1)
        #expect(s.foreground.red < 1, "peak white would glare against tone-mapped HDR")
        #expect(s.outline.rgb24 == 0x000000)
        #expect(s.outline.alpha == 1, "a translucent border would band where outline passes overlap")
        #expect(s.outlineWidthRatio > 0, "the boxless look depends entirely on the border")
    }

    /// The user-configurable four must start at their neutral values, or a fresh install
    /// would render pre-adjusted subtitles.
    @Test("the overlay-only controls start neutral")
    func userControlsStartNeutral() {
        let s = SubtitleStyle.standard
        #expect(s.fontScale == 1.0)
        #expect(s.fontDesign == .sansSerif)
        #expect(s.background == .outlineShadow)
        #expect(s.verticalOffsetRatio == 0)
    }

    /// Every geometry knob is a *ratio of the font size*, so the look survives the
    /// phone/iPad/tvOS base-size differences unchanged.
    @Test("the shadow is a real, resolution-independent drop shadow")
    func shadowIsResolutionIndependent() {
        let s = SubtitleStyle.standard
        #expect(s.shadowOpacity > 0 && s.shadowOpacity < 1)
        #expect(s.shadowYOffsetRatio > 0, "a zero offset would hide the shadow behind the glyph")
    }
}

@Suite("SubtitleStyle.with(_:)")
struct SubtitleStyleBuilderTests {

    /// `with` is the ONE mutation path for the settings controls (the stored properties
    /// are `let`). Its contract is surgical: change what the builder exposes, carry
    /// everything else through untouched.
    @Test("changing one exposed field leaves every other field alone")
    func mutatesOnlyTheTargetedField() {
        let base = SubtitleStyle.standard
        let scaled = base.with { $0.fontScale = 1.75 }

        #expect(scaled.fontScale == 1.75)
        #expect(scaled.foreground == base.foreground)
        #expect(scaled.outline == base.outline)
        #expect(scaled.outlineWidthRatio == base.outlineWidthRatio)
        #expect(scaled.shadowOpacity == base.shadowOpacity)
        #expect(scaled.shadowYOffsetRatio == base.shadowYOffsetRatio)
        #expect(scaled.fontDesign == base.fontDesign)
        #expect(scaled.background == base.background)
        #expect(scaled.verticalOffsetRatio == base.verticalOffsetRatio)
    }

    @Test("value semantics: the original is never mutated")
    func originalIsUntouched() {
        let base = SubtitleStyle.standard
        _ = base.with { $0.fontScale = 2.0; $0.background = .opaqueBox }
        #expect(base == SubtitleStyle.standard)
    }

    @Test("every exposed control round-trips through the builder")
    func allExposedControlsRoundTrip() {
        let red = SubtitleStyle.RGBA(red: 1, green: 0, blue: 0)
        let tuned = SubtitleStyle.standard.with {
            $0.foreground = red
            $0.fontScale = 0.5
            $0.fontDesign = .monospaced
            $0.background = .opaqueBox
            $0.verticalOffsetRatio = 0.12
        }
        #expect(tuned.foreground == red)
        #expect(tuned.fontScale == 0.5)
        #expect(tuned.fontDesign == .monospaced)
        #expect(tuned.background == .opaqueBox)
        #expect(tuned.verticalOffsetRatio == 0.12)
    }

    @Test("successive edits compose instead of resetting each other")
    func editsCompose() {
        let tuned = SubtitleStyle.standard
            .with { $0.fontScale = 1.5 }
            .with { $0.background = .opaqueBox }
        #expect(tuned.fontScale == 1.5)
        #expect(tuned.background == .opaqueBox)
    }
}

/// The style is persisted in the subtitle settings, so its `Codable` shape and the two
/// enums' raw values are an on-disk contract — a renamed case would silently reset a
/// user's chosen look.
@Suite("SubtitleStyle persistence")
struct SubtitleStylePersistenceTests {

    @Test("a fully-customised style survives a JSON round trip")
    func codableRoundTrip() throws {
        let original = SubtitleStyle.standard.with {
            $0.foreground = SubtitleStyle.RGBA(red: 0.1, green: 0.2, blue: 0.3, alpha: 0.9)
            $0.fontScale = 1.85
            $0.fontDesign = .serif
            $0.background = .opaqueBox
            $0.verticalOffsetRatio = 0.2
        }
        let decoded = try JSONDecoder().decode(
            SubtitleStyle.self, from: JSONEncoder().encode(original)
        )
        #expect(decoded == original)
    }

    @Test("SubtitleFontDesign raw values are stable", arguments: [
        (SubtitleFontDesign.sansSerif, "sansSerif"),
        (.serif, "serif"),
        (.monospaced, "monospaced"),
    ])
    func fontDesignRawValues(design: SubtitleFontDesign, raw: String) {
        #expect(design.rawValue == raw)
        #expect(SubtitleFontDesign(rawValue: raw) == design)
    }

    @Test("SubtitleBackground raw values are stable", arguments: [
        (SubtitleBackground.outlineShadow, "outlineShadow"),
        (.opaqueBox, "opaqueBox"),
    ])
    func backgroundRawValues(background: SubtitleBackground, raw: String) {
        #expect(background.rawValue == raw)
        #expect(SubtitleBackground(rawValue: raw) == background)
    }

    /// The settings pickers enumerate these, so a new case must not be silently absent
    /// from the UI.
    @Test("both settings enums enumerate every case they offer")
    func caseIterableCoversTheUI() {
        #expect(SubtitleFontDesign.allCases.count == 3)
        #expect(SubtitleBackground.allCases.count == 2)
        #expect(Set(SubtitleFontDesign.allCases.map(\.rawValue)).count
                == SubtitleFontDesign.allCases.count)
    }
}
