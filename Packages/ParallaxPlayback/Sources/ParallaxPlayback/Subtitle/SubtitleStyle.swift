import Foundation

/// The canonical look for plain-text subtitles, shared by every renderer so all
/// three paths read identically:
/// - the app's client-side overlay (sidecar VTT — the common case for both engines),
/// - AVKit's native WebVTT rendering (direct-play embedded tracks),
/// - VLC's freetype renderer (direct-play embedded SRT on the VLC engine).
/// ASS/SSA keep their authored styles (libass); this is the *unstyled* text look only.
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
    /// Glyph border. Opaque, so the overlay's overlapping outline passes can't band.
    public let outline: RGBA
    /// Border thickness as a fraction of the font size (resolution-independent).
    public let outlineWidthRatio: Double
    /// Soft drop shadow under the border, for separation on busy scenes. Only the
    /// overlay can honor these (AVKit's uniform edge and VLC's shadow defaults are
    /// not parameterized here), but they're part of the one canonical look — tune
    /// them with the palette, not in a view file. Black, at this opacity:
    public let shadowOpacity: Double
    /// Shadow blur radius as a fraction of the font size.
    public let shadowRadiusRatio: Double
    /// Shadow vertical offset as a fraction of the font size.
    public let shadowYOffsetRatio: Double

    // MARK: User-configurable (v1 subtitle settings) — overlay-only.
    // These four are honored ONLY by the client overlay (SubtitleOverlayView);
    // engine-native renderers (libass/AVKit) read `.standard` and ignore them,
    // so they can never reach (or break) a self-positioned ASS/CJK track.

    /// Cue size multiplier on the per-surface base size (`PlayerMetrics.subtitleFontSize`).
    /// 1.0 == the proven per-device base; the size control scales this 0.5…2.0.
    public let fontScale: Double
    /// Glyph family for the overlay's SwiftUI `Text`, mapped to `Font.Design` in the
    /// app. Engine-native tracks are unaffected (no font-selection API on iOS).
    public let fontDesign: SubtitleFontDesign
    /// Legibility backing: the canonical outline-ring + shadow, OR an opaque box
    /// (mutually exclusive — a box carries its own contrast, so no ring/shadow).
    public let background: SubtitleBackground
    /// Lift above the bottom anchor as a fraction of the surface height
    /// (resolution-independent across phone/iPad/tvOS). 0 == rest at the base inset.
    public let verticalOffsetRatio: Double

    public init(foreground: RGBA, outline: RGBA, outlineWidthRatio: Double,
                shadowOpacity: Double, shadowRadiusRatio: Double, shadowYOffsetRatio: Double,
                fontScale: Double = 1.0,
                fontDesign: SubtitleFontDesign = .sansSerif,
                background: SubtitleBackground = .outlineShadow,
                verticalOffsetRatio: Double = 0) {
        self.foreground = foreground
        self.outline = outline
        self.outlineWidthRatio = outlineWidthRatio
        self.shadowOpacity = shadowOpacity
        self.shadowRadiusRatio = shadowRadiusRatio
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
                shadowOpacity: base.shadowOpacity, shadowRadiusRatio: base.shadowRadiusRatio,
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
        shadowRadiusRatio: 0.10,
        shadowYOffsetRatio: 0.04
    )
}

/// Subtitle glyph family for the client overlay. Maps to SwiftUI `Font.Design` in
/// the app (`.default`/`.serif`/`.monospaced`); a plain enum here so the package
/// stays UI-framework-free. NOTE: `.serif` is New York (Latin) — CJK glyphs fall
/// back via the system cascade and may not resolve to a serif face. Verify by
/// render before relying on serif for CJK (see the subtitle-settings spec).
public enum SubtitleFontDesign: String, Sendable, Hashable, Codable, CaseIterable {
    case sansSerif
    case serif
    case monospaced
}

/// The overlay's legibility backing. `.outlineShadow` is the canonical boxless look
/// (black glyph ring + soft shadow); `.opaqueBox` is a solid panel behind the text
/// with neither ring nor shadow. Mutually exclusive by design.
public enum SubtitleBackground: String, Sendable, Hashable, Codable, CaseIterable {
    case outlineShadow
    case opaqueBox
}
