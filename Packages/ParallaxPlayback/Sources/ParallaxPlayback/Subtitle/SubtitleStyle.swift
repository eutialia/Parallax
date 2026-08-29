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
/// Boxless by design: a black glyph border plus each renderer's soft shadow carry
/// legibility on light content, and the fill sits below full white so cues don't
/// read as the brightest object in a tone-mapped HDR frame.
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
    /// Glyph border. Opaque, so it reads as a solid ring against the video instead
    /// of letting the frame show through (libass strokes it in one pass).
    public let outline: RGBA
    /// Border thickness as a fraction of the font size (resolution-independent).
    public let outlineWidthRatio: Double
    /// Soft drop shadow under the border, for separation on busy scenes. The overlay
    /// and VLC's freetype renderer both honor it (AVKit's uniform edge does not) —
    /// tune it with the palette, not in a view file. Black, at this opacity:
    public let shadowOpacity: Double
    /// Shadow vertical offset as a fraction of the font size.
    public let shadowYOffsetRatio: Double

    // MARK: User-configurable (v1 subtitle settings).
    // These style the PLAIN-TEXT subtitles we draw ourselves. The client sidecar
    // renderer honors all four, live. VLC's simple freetype renderer (embedded plain
    // text) honors size, family, colour and border too — via `EngineSubtitleTextStyle`
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
    /// Legibility backing: the canonical outline-ring + shadow, OR an opaque box
    /// (mutually exclusive — a box carries its own contrast, so no ring/shadow).
    public let background: SubtitleBackground
    /// Lift above the bottom anchor as a fraction of the surface height
    /// (resolution-independent across phone/iPad/tvOS). 0 == rest at the base inset.
    public let verticalOffsetRatio: Double

    public init(foreground: RGBA, outline: RGBA, outlineWidthRatio: Double,
                shadowOpacity: Double, shadowYOffsetRatio: Double,
                fontScale: Double = 1.0,
                fontDesign: SubtitleFontDesign = .sansSerif,
                background: SubtitleBackground = .outlineShadow,
                verticalOffsetRatio: Double = 0) {
        self.foreground = foreground
        self.outline = outline
        self.outlineWidthRatio = outlineWidthRatio
        self.shadowOpacity = shadowOpacity
        self.shadowYOffsetRatio = shadowYOffsetRatio
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
        private let base: SubtitleStyle

        init(_ s: SubtitleStyle) {
            self.foreground = s.foreground
            self.fontScale = s.fontScale
            self.fontDesign = s.fontDesign
            self.background = s.background
            self.verticalOffsetRatio = s.verticalOffsetRatio
            self.base = s
        }

        var style: SubtitleStyle {
            SubtitleStyle(
                foreground: foreground, outline: base.outline,
                outlineWidthRatio: base.outlineWidthRatio,
                shadowOpacity: base.shadowOpacity,
                shadowYOffsetRatio: base.shadowYOffsetRatio,
                fontScale: fontScale, fontDesign: fontDesign,
                background: background, verticalOffsetRatio: verticalOffsetRatio
            )
        }
    }

    /// 92% white in a solid black border — "white" at a glance, without the
    /// peak-white glare of pure `#FFFFFF` next to tone-mapped HDR video.
    public static let standard = SubtitleStyle(
        foreground: RGBA(red: 0.92, green: 0.92, blue: 0.92),
        outline: RGBA(red: 0, green: 0, blue: 0),
        outlineWidthRatio: 0.06,
        shadowOpacity: 0.55,
        shadowYOffsetRatio: 0.04
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

/// The overlay's legibility backing. `.outlineShadow` is the canonical boxless look
/// (black glyph ring + soft shadow); `.opaqueBox` is a solid panel behind the text
/// with neither ring nor shadow. Mutually exclusive by design.
public enum SubtitleBackground: String, Sendable, Hashable, Codable, CaseIterable {
    case outlineShadow
    case opaqueBox
}
