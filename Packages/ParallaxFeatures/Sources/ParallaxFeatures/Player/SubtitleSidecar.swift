import Foundation
import CoreGraphics
import ParallaxPlayback
import ParallaxSubtitles

extension SubtitleStyle {
    /// The user's overlay style expressed as the renderer's selective override,
    /// with the caller-computed font scale and the tuned rest position as
    /// script-unit margins. The canonical ring rides along as a fraction of the em;
    /// the renderer turns it into script units, and libass scales it with the font
    /// scale exactly as it scales the glyphs.
    ///
    /// The family stays the design bucket's own mapping, where the sans bucket
    /// has no libass name override — the synthesized script already names that
    /// family in its style.
    ///
    /// The serif design is weight 600 everywhere, and one style-level Bold is
    /// all it takes: libass only synthesizes bold when the request beats the
    /// face's own weight by a margin, so the real Noto Serif SemiBold Latin
    /// stays as drawn and every Regular-only script face is emboldened.
    public func rendererOverride(
        fontScale: Double,
        marginVertical: Double? = nil,
        marginHorizontal: Double? = nil
    ) -> SubtitleStyleOverride {
        SubtitleStyleOverride(
            fontFamily: fontDesign.rendererFamily,
            fontScale: fontScale,
            primaryColor: SubtitleColor(
                red: foreground.red, green: foreground.green,
                blue: foreground.blue, alpha: foreground.alpha
            ),
            bold: fontDesign == .serif,
            opaqueBox: background == .opaqueBox,
            outlineEmRatio: Self.outlineWidthRatio,
            marginVertical: marginVertical,
            marginHorizontal: marginHorizontal
        )
    }
}

extension SubtitleFontDesign {
    /// The bundled Latin face this design bucket renders through; every other
    /// script is reached from it by the renderer's per-run tagging.
    /// `nil` for sans: that IS the renderer's default family, and leaving the
    /// override's font-name field unset keeps libass' FONT_NAME bit off for
    /// converted cues whose synthesized style already names it.
    public var rendererFamily: String? {
        switch self {
        case .sansSerif: nil
        case .serif: SubtitleFontBundle.serifCueFamily
        }
    }

    /// The same mapping with the sans bucket resolved — for callers that need a
    /// real family name, which is what the CJK font plan is built around.
    public var resolvedRendererFamily: String {
        rendererFamily ?? SubtitleFontBundle.sansFamily
    }
}
