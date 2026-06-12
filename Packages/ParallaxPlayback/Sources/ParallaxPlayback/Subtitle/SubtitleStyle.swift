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
public struct SubtitleStyle: Sendable, Hashable {
    /// sRGB components 0...1 — kept primitive so the package stays UI-framework-free;
    /// each renderer maps these into its own color type.
    public struct RGBA: Sendable, Hashable {
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

    public init(foreground: RGBA, outline: RGBA, outlineWidthRatio: Double,
                shadowOpacity: Double, shadowRadiusRatio: Double, shadowYOffsetRatio: Double) {
        self.foreground = foreground
        self.outline = outline
        self.outlineWidthRatio = outlineWidthRatio
        self.shadowOpacity = shadowOpacity
        self.shadowRadiusRatio = shadowRadiusRatio
        self.shadowYOffsetRatio = shadowYOffsetRatio
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
