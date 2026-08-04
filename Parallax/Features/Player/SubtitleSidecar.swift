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
    /// The user's overlay style expressed as the renderer's selective override, with
    /// the caller-computed font scale (converted tracks remap the per-device tuned
    /// size; authored tracks scale the creator's own sizes). Font-family mapping is
    /// approximate on purpose: libass resolves real family names through CoreText,
    /// and the design buckets pick a face every device ships.
    func rendererOverride(fontScale: Double) -> SubtitleStyleOverride {
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
            opaqueBox: background == .opaqueBox
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
