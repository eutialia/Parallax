import Foundation

/// The canonical look for plain-text subtitles, shared by every renderer that draws
/// them:
/// - the app's client-side sidecar renderer (libass via `ParallaxSubtitles` — the
///   common case for both engines; this style maps into its selective override),
/// - AVKit's native WebVTT rendering (direct-play embedded tracks),
/// - VLC's freetype renderer (direct-play embedded SRT on the VLC engine).
/// Authored ASS/SSA never takes any of this: a creator's script carries its own
/// colours, sizes, borders and placement, and that typesetting is theirs to keep.
/// The one thing the renderer changes about such a track is the typeface, because
/// the fonts it names are not on the device.
///
/// Boxless by design: ONE soft black drop shadow carries legibility on light
/// content, and the fill sits below full white so cues don't read as the
/// brightest object in a tone-mapped HDR frame. There is no glyph ring — a ring
/// plus a hard shadow put more dark than ink around small text and filled the
/// counters in.
public struct SubtitleStyle: Sendable, Hashable, Codable {
    /// sRGB components 0...1 — kept primitive so the package stays UI-framework-free;
    /// each renderer maps these into its own color type.
    public struct RGBA: Sendable, Hashable, Codable {
        public let red: Double
        public let green: Double
        public let blue: Double
        public let alpha: Double

        public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
            self.red = red
            self.green = green
            self.blue = blue
            self.alpha = alpha
        }

        /// 24-bit `0xRRGGBB` (alpha dropped) — the integer form of VLC's `freetype-color`.
        public var rgb24: Int {
            (Int((red * 255).rounded()) << 16)
                | (Int((green * 255).rounded()) << 8)
                | Int((blue * 255).rounded())
        }
    }

    /// Glyph fill.
    public let foreground: RGBA

    // MARK: Canonical shadow (code, not a setting)
    // Every ratio is a fraction of the font size, so the look survives the
    // phone/iPad/tvOS base-size differences unchanged. Static on purpose: an
    // earlier build persisted the shadow with the style, which froze it into the
    // settings of everyone who had ever touched a subtitle control, and no retune
    // could reach them. Those blobs' keys are unknown to the decoder and ignored.

    /// Gaussian blur radius of the shadow. The client renderer blurs; VLC's
    /// freetype renderer cannot and lands one step short.
    public static let shadowBlurRatio = 0.05
    /// Black, at this opacity.
    public static let shadowOpacity = 0.80
    /// Shadow offset, applied down AND right (both renderers offset diagonally).
    public static let shadowOffsetRatio = 0.03

    // MARK: User-configurable (v1 subtitle settings).
    // These style the PLAIN-TEXT subtitles we draw ourselves. The client sidecar
    // renderer honors all four, live. VLC's simple freetype renderer (embedded plain
    // text) honors size, family and colour too — via `EngineSubtitleTextStyle`
    // on the asset, so they are fixed for the life of the decoder and a change applies
    // from the next item; `verticalOffsetRatio` is client-only. An AUTHORED ASS/SSA
    // track is never restyled by any of them: its creator's colours, sizes and
    // placement stand, and only its font family is mapped onto a bundled face.

    /// Cue size multiplier on the proven per-device base size
    /// (`PlayerMetrics.subtitleFontSize`, remapped onto the renderer's script base
    /// by the overlay). 1.0 == the tuned base; the size control scales this 0.5…2.0.
    public let fontScale: Double
    /// Glyph family, mapped to one of the two bundled Noto faces. The client renderer
    /// takes it as a style override; VLC's own renderers take it as the `:ssa-fontsdir`
    /// media option plus the `--freetype-font` instance argument the app materializes
    /// it under.
    public let fontDesign: SubtitleFontDesign
    /// Legibility backing: the canonical soft shadow, OR an opaque box (mutually
    /// exclusive — a box carries its own contrast, so it takes no shadow).
    public let background: SubtitleBackground
    /// Lift above the bottom anchor as a fraction of the surface height
    /// (resolution-independent across phone/iPad/tvOS). 0 == rest at the base inset.
    public let verticalOffsetRatio: Double

    public init(foreground: RGBA,
                fontScale: Double = 1.0,
                fontDesign: SubtitleFontDesign = .sansSerif,
                background: SubtitleBackground = .shadow,
                verticalOffsetRatio: Double = 0) {
        self.foreground = foreground
        self.fontScale = fontScale
        self.fontDesign = fontDesign
        self.background = background
        self.verticalOffsetRatio = verticalOffsetRatio
    }

    /// Returns a copy with `transform` applied — the one mutation path for the
    /// settings controls, since the stored properties are `let` (value semantics).
    public func with(_ transform: (inout Builder) -> Void) -> SubtitleStyle {
        var b = Builder(self)
        transform(&b)
        return b.style
    }

    /// Mutable façade over `SubtitleStyle`'s `let` fields for `with(_:)`.
    public struct Builder {
        public var foreground: RGBA
        public var fontScale: Double
        public var fontDesign: SubtitleFontDesign
        public var background: SubtitleBackground
        public var verticalOffsetRatio: Double

        init(_ s: SubtitleStyle) {
            self.foreground = s.foreground
            self.fontScale = s.fontScale
            self.fontDesign = s.fontDesign
            self.background = s.background
            self.verticalOffsetRatio = s.verticalOffsetRatio
        }

        var style: SubtitleStyle {
            SubtitleStyle(
                foreground: foreground, fontScale: fontScale, fontDesign: fontDesign,
                background: background, verticalOffsetRatio: verticalOffsetRatio
            )
        }
    }

    /// 92% white over the canonical shadow — "white" at a glance, without the
    /// peak-white glare of pure `#FFFFFF` next to tone-mapped HDR video.
    public static let standard = SubtitleStyle(
        foreground: RGBA(red: 0.92, green: 0.92, blue: 0.92)
    )
}

/// Subtitle glyph family for the client renderer. A plain enum here so the package
/// stays UI-framework-free; the app maps each case to one of the two bundled Noto
/// Latin faces, and the renderer routes every other script to that design's face
/// for it — so a Japanese line under `.serif` lands on a real Mincho face
/// (Noto Serif CJK) rather than falling back.
///
/// There is no monospaced case: the bundle has no monospaced answer, and a
/// design bucket that silently rendered as sans would be a lie in the picker.
public enum SubtitleFontDesign: String, Sendable, Hashable, Codable, CaseIterable {
    case sansSerif
    case serif

    /// Unknown raw values decode to `.sansSerif` instead of throwing. The whole
    /// `SubtitleStyle` is persisted as one JSON blob, so a rejected font design
    /// would fail the container's decode and silently reset the user's color,
    /// size and position too. A "monospaced" written by an older build lands here.
    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = SubtitleFontDesign(rawValue: raw) ?? .sansSerif
    }
}

/// The overlay's legibility backing. `.opaqueBox` is a solid panel behind the
/// text, which carries its own contrast and so takes no shadow. Mutually
/// exclusive by design.
public enum SubtitleBackground: String, Sendable, Hashable, Codable, CaseIterable {
    /// The canonical boxless look: one soft black drop shadow, no glyph ring.
    /// The raw value is the on-disk contract from before the ring's removal.
    case shadow = "outlineShadow"
    case opaqueBox
}
