import CoreGraphics
import ParallaxPlayback
import ParallaxSubtitles

/// What the sidecar renderer was loaded with. The debug panel shows it, and the
/// style policy keys off `format`: SRT/VTT carry no authored look, so the user's
/// style always applies; ASS/SSA keeps its creator styling unless the user opted
/// into overriding it.
struct SidecarSubtitleInfo: Equatable {
    let format: SubtitleSourceFormat
    let byteCount: Int
}

extension SubtitleSourceFormat {
    /// Maps a sidecar file/URL extension to the renderer's ingest format. Anything
    /// unrecognized is treated as WebVTT — Jellyfin's conversion fallback serves
    /// VTT for every format we don't request verbatim.
    init(sidecarExtension ext: String) {
        switch ext.lowercased() {
        case "ass": self = .ass
        case "ssa": self = .ssa
        case "srt": self = .srt
        default: self = .vtt
        }
    }
}

extension SubtitleStyle {
    /// The converted-track override for one playback geometry — THE single source
    /// for both the player overlay and the settings live preview, so the preview
    /// cannot drift from what actually renders. Two mappings live here:
    /// - the tuned per-device cue size (`PlayerMetrics.subtitleFontSize`) remapped
    ///   onto the synthesized script's font base, keyed on the CANVAS height (the
    ///   full surface for converted tracks — their cells map to the device);
    /// - the font's own win box multiplied BACK: libass sizes VSFilter-style by
    ///   dividing the style size by that box, so without the factor the size that
    ///   renders is ~14% under the size that was tuned.
    @MainActor
    func convertedRendererOverride(surface: CGSize, canvas: CGRect) -> SubtitleStyleOverride {
        let metrics = PlayerMetrics.forSurface(surface)
        let scriptPt = canvas.height * SubtitleRenderer.convertedScriptFontFraction
        let family = fontDesign.rendererFamily ?? SubtitleRenderer.standardFontFamily
        let base = scriptPt > 0 ? (metrics.subtitleFontSize * fontScale) / scriptPt : fontScale
        // The em the cue actually renders at, in script units — the base for
        // border and shadow, which libass does NOT scale with the font scale.
        // Left constant they read heavier the smaller the text (the "tint").
        let emUnits = SubtitleRenderer.convertedScriptFontSize * base
        return rendererOverride(
            fontScale: base * SubtitleFontMetrics.emBoxFactor(forFamily: family),
            outlineWidth: outlineWidthRatio * emUnits,
            shadowOffset: shadowYOffsetRatio * emUnits,
            shadowAlpha: shadowOpacity
        )
    }

    /// The user's overlay style expressed as the renderer's selective override, with
    /// the caller-computed font scale (converted tracks remap the per-device tuned
    /// size; authored tracks scale the creator's own sizes) and optional script-unit
    /// border/shadow (converted tracks size them proportional to the cue; authored
    /// tracks keep the synthesized defaults). Font-family mapping is approximate on
    /// purpose: libass resolves real family names through CoreText, and the design
    /// buckets pick a face every device ships.
    func rendererOverride(
        fontScale: Double,
        outlineWidth: Double? = nil,
        shadowOffset: Double? = nil,
        shadowAlpha: Double? = nil
    ) -> SubtitleStyleOverride {
        SubtitleStyleOverride(
            fontFamily: fontDesign.rendererFamily,
            fontScale: fontScale,
            primaryColor: SubtitleColor(
                red: foreground.red, green: foreground.green,
                blue: foreground.blue, alpha: foreground.alpha
            ),
            outlineColor: SubtitleColor(
                red: outline.red, green: outline.green,
                blue: outline.blue, alpha: outline.alpha
            ),
            opaqueBox: background == .opaqueBox,
            outlineWidth: outlineWidth,
            shadowOffset: shadowOffset,
            shadowAlpha: shadowAlpha
        )
    }
}

extension SubtitleFontDesign {
    /// nil = the renderer's default family (Helvetica Neue), matching the sans bucket.
    var rendererFamily: String? {
        switch self {
        case .sansSerif: nil
        case .serif: "Times New Roman"
        case .monospaced: "Courier New"
        }
    }
}
