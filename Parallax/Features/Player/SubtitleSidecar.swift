import Foundation
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
    /// cannot drift from what actually renders. Three mappings live here:
    /// - the tuned per-device cue size (`PlayerMetrics.subtitleFontSize`) remapped
    ///   onto the synthesized script's font base, keyed on the CANVAS height (the
    ///   full surface for converted tracks — their cells map to the device);
    /// - the font's own win box multiplied BACK: libass sizes VSFilter-style by
    ///   dividing the style size by that box, so without the factor the size that
    ///   renders is ~14% under the size that was tuned;
    /// - the tuned rest position (`subtitleBottom`/`subtitleInsetX`) expressed as
    ///   script-unit margins for THIS canvas. The synthesized script's own margin
    ///   is proportional (5% of the canvas), which parked default cues ~15pt off
    ///   an iPhone's landscape bottom — inside the home-indicator band.
    @MainActor
    func convertedRendererOverride(surface: CGSize, canvas: CGRect) -> SubtitleStyleOverride {
        let metrics = PlayerMetrics.forSurface(surface)
        let scriptPt = canvas.height * SubtitleRenderer.convertedScriptFontFraction
        let family = fontDesign.resolvedRendererFamily
        let base = scriptPt > 0 ? (metrics.subtitleFontSize * fontScale) / scriptPt : fontScale
        let playRes = SubtitleRenderer.convertedScriptPlayRes
        return rendererOverride(
            fontScale: base * SubtitleFontMetrics.emBoxFactor(forFamily: family),
            emHeightRatio: SubtitleRenderer.convertedScriptFontFraction * base,
            shadowAlpha: shadowOpacity,
            marginVertical: canvas.height > 0
                ? metrics.subtitleBottom / canvas.height * playRes.height : nil,
            marginHorizontal: canvas.width > 0
                ? metrics.subtitleInsetX / canvas.width * playRes.width : nil
        )
    }

    /// The authored-track override for "Use My Style" — the creator's script with
    /// the user's font, size, colour and border swapped in (never their placement;
    /// see `SubtitleStylePolicy.authoredOptIn`).
    ///
    /// Two things this fixes over pushing raw constants:
    /// - **Border geometry tracks Size.** Outline and shadow are derived from the
    ///   em the cue renders at, so the ring stays the same proportion of the glyph
    ///   at 50% as at 200%. libass does not scale them with the font scale.
    /// - **Size gets the em-box compensation** converted cues get: libass sizes
    ///   VSFilter-style by dividing the style size by the font's declared win box,
    ///   so without the factor "150%" renders ~31% smaller than it reads.
    ///
    /// Nothing here is in script units: border and shadow are fractions of the
    /// em, and the em itself is a fraction of the canvas — `SubtitleRenderer`
    /// turns them into the units libass wants. Measured on the render path, a
    /// script-unit border draws the same pixels whatever the fansub's PlayRes,
    /// so the app must NOT "correct" for the script's resolution; doing that
    /// made 1080p scripts' rings 1.5x heavier.
    func authoredRendererOverride() -> SubtitleStyleOverride {
        let family = fontDesign.resolvedRendererFamily
        return rendererOverride(
            fontScale: fontScale * SubtitleFontMetrics.emBoxFactor(forFamily: family),
            fontFamily: family,
            emHeightRatio: SubtitleRenderer.convertedScriptFontFraction * fontScale,
            shadowAlpha: shadowOpacity
        )
    }

    /// The user's overlay style expressed as the renderer's selective override, with
    /// the caller-computed font scale (converted tracks remap the per-device tuned
    /// size; authored tracks scale the creator's own sizes), the em the cue renders
    /// at as a fraction of the script canvas, and — converted tracks only — the
    /// tuned rest position as script-unit margins. Border and shadow always ride
    /// along as fractions of that em; the renderer turns them into script units
    /// against whichever canvas the loaded script declares.
    ///
    /// `fontFamily` nil means the design bucket's own mapping, where the sans
    /// bucket has no libass name override. Authored tracks must pass the
    /// resolved family instead: without it the override's font-name flag stays
    /// unset and the creator's typeface silently survives "Use My Style".
    func rendererOverride(
        fontScale: Double,
        fontFamily: String? = nil,
        emHeightRatio: Double? = nil,
        shadowAlpha: Double? = nil,
        marginVertical: Double? = nil,
        marginHorizontal: Double? = nil
    ) -> SubtitleStyleOverride {
        SubtitleStyleOverride(
            fontFamily: fontFamily ?? fontDesign.rendererFamily,
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
            emHeightRatio: emHeightRatio,
            outlineEmRatio: outlineWidthRatio,
            shadowEmRatio: shadowYOffsetRatio,
            shadowAlpha: shadowAlpha,
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
    var rendererFamily: String? {
        switch self {
        case .sansSerif: nil
        case .serif: SubtitleFontBundle.serifFamily
        }
    }

    /// The same mapping with the sans bucket resolved — for callers that need a
    /// real family name (the CJK font plan, and authored tracks under "Use My
    /// Style", where a nil would leave the creator's typeface in place).
    var resolvedRendererFamily: String {
        rendererFamily ?? SubtitleFontBundle.sansFamily
    }

    /// The same bucket in the font bundle's vocabulary — for callers that ask the bundle
    /// for a family per SCRIPT (VLC's own renderers, which take a family name and a font
    /// directory rather than a style override).
    var bundleDesign: SubtitleFontBundle.Design {
        switch self {
        case .sansSerif: .sans
        case .serif: .serif
        }
    }
}
