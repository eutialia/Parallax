import CoreGraphics
import Libass

/// A subtitle colour in the sRGB space.
public struct SubtitleColor: Sendable, Equatable, Hashable {
    public var red: Double
    public var green: Double
    public var blue: Double
    /// 1 = fully opaque.
    public var alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    /// ASS packs colours as `0xRRGGBBAA` where the last byte is TRANSPARENCY:
    /// zero means opaque.
    var assPacked: UInt32 {
        func byte(_ value: Double) -> UInt32 { UInt32(max(0, min(1, value)) * 255) }
        return byte(red) << 24 | byte(green) << 16 | byte(blue) << 8 | (255 - byte(alpha))
    }
}

/// A user's preferred look, applied on top of whatever the script authored.
///
/// Every field is optional and only the ones that are set are handed to libass,
/// so a caller who only wants a bigger font does not also flatten the script's
/// colours. Overrides apply to events that look like ordinary dialogue; signs
/// and other positioned text keep their authored styling.
///
/// Colour is all-or-nothing: libass has a single flag covering all four style
/// colours, so setting `primaryColor`, `outlineColor` OR `opaqueBox` also
/// replaces the secondary (karaoke fill) and back (box/shadow) colours with
/// plain defaults. Leave all three nil to keep the script's palette as authored.
public struct SubtitleStyleOverride: Sendable, Equatable {

    public var fontFamily: String?
    /// Multiplies the authored font size. 1 leaves it alone.
    public var fontScale: Double?
    public var primaryColor: SubtitleColor?
    public var outlineColor: SubtitleColor?

    /// Draw each line on a filled rectangle instead of outlining the glyphs.
    ///
    /// This is the caption "opaque box" style. It replaces the border treatment
    /// wholesale, and because the box is painted with the style's back colour it
    /// also forces the colour override on — see the note above.
    public var opaqueBox: Bool?

    /// Border thickness in SCRIPT units (the synthesized scripts author against
    /// a 720-line canvas). Nil keeps the synthesized default — a constant, which
    /// reads proportionally heavier the smaller the text; callers that scale the
    /// font should scale this with it.
    public var outlineWidth: Double?
    /// Drop-shadow offset in script units, boxless look only (the box carries
    /// its own contrast). Nil keeps the synthesized default.
    public var shadowOffset: Double?
    /// Shadow opacity for the boxless look. Nil keeps the default half black.
    public var shadowAlpha: Double?

    /// Rest distance from the bottom of the canvas, in script units. libass has
    /// a single flag for all three margins, so setting either margin field
    /// replaces the authored left/right/vertical margins together — a caller
    /// who sets one should set both.
    public var marginVertical: Double?
    /// Left AND right inset in script units, applied symmetrically.
    public var marginHorizontal: Double?

    public init(
        fontFamily: String? = nil,
        fontScale: Double? = nil,
        primaryColor: SubtitleColor? = nil,
        outlineColor: SubtitleColor? = nil,
        opaqueBox: Bool? = nil,
        outlineWidth: Double? = nil,
        shadowOffset: Double? = nil,
        shadowAlpha: Double? = nil,
        marginVertical: Double? = nil,
        marginHorizontal: Double? = nil
    ) {
        self.fontFamily = fontFamily
        self.fontScale = fontScale
        self.primaryColor = primaryColor
        self.outlineColor = outlineColor
        self.opaqueBox = opaqueBox
        self.outlineWidth = outlineWidth
        self.shadowOffset = shadowOffset
        self.shadowAlpha = shadowAlpha
        self.marginVertical = marginVertical
        self.marginHorizontal = marginHorizontal
    }

    /// True when nothing would change.
    var isNoOp: Bool {
        fontFamily == nil && fontScale == nil && primaryColor == nil
            && outlineColor == nil && opaqueBox == nil && !overridesMargins
    }

    /// Whether the border fields have to be pushed through.
    var overridesBorder: Bool { opaqueBox != nil }

    /// Whether any colour field has to be pushed through. The opaque box counts:
    /// its fill IS the back colour.
    var overridesColors: Bool {
        primaryColor != nil || outlineColor != nil || opaqueBox != nil
    }

    /// Whether the margin fields have to be pushed through.
    var overridesMargins: Bool { marginVertical != nil || marginHorizontal != nil }

    /// The `ASS_OverrideBits` mask matching the fields that are set.
    var overrideBits: Int32 {
        var bits: Int32 = 0
        if fontFamily != nil {
            bits |= Int32(ASS_OVERRIDE_BIT_FONT_NAME.rawValue)
        }
        if fontScale != nil {
            // Without this bit the scale would also blow up positioned signs.
            bits |= Int32(ASS_OVERRIDE_BIT_SELECTIVE_FONT_SCALE.rawValue)
        }
        if overridesColors {
            bits |= Int32(ASS_OVERRIDE_BIT_COLORS.rawValue)
        }
        if overridesBorder {
            // Covers BorderStyle, Outline and Shadow together.
            bits |= Int32(ASS_OVERRIDE_BIT_BORDER.rawValue)
        }
        if overridesMargins {
            // Covers MarginL, MarginR and MarginV together.
            bits |= Int32(ASS_OVERRIDE_BIT_MARGINS.rawValue)
        }
        return bits
    }
}
