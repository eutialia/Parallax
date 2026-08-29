import Foundation
import CoreGraphics
import ParallaxPlayback
import ParallaxSubtitles

/// What the sidecar renderer was loaded with. The debug panel shows it, and the
/// style push keys off `format`: SRT/VTT carry no authored look, so the user's
/// style always applies; ASS/SSA keeps its creator's, always.
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

    /// THE one place the two subtitle paths' sizes are related: the divisor for VLC's
    /// `--freetype-rel-fontsize`, which sizes an embedded SRT the engine draws itself so
    /// it matches the cue the client renderer would have drawn for the same style.
    ///
    /// The freetype module stores `100/N` as a percentage of the video output height,
    /// so `em = outputHeight / N` — relative on purpose: `freetype-fontsize` is absolute
    /// pixels and VLC 3.0 renders the SPU at `max(source, placed)` resolution, so a 4K
    /// source would halve an absolute size.
    ///
    /// `videoRectHeight` assumes a 16:9 picture aspect-fitted into the surface. The real
    /// video dimensions are unknown at load (the library instance is built before the
    /// demux reports them), and 16:9 bounds the error for the aspects that aren't.
    func freetypeRelativeFontSize(surface: CGSize, metrics: PlayerMetrics) -> Int {
        let em = metrics.subtitleFontSize * fontScale
        guard em > 0 else { return Self.freetypeRelativeFontSizeFloor }
        let videoRectHeight = min(surface.height, surface.width * 9 / 16)
        return max(Self.freetypeRelativeFontSizeFloor, Int((videoRectHeight / em).rounded()))
    }

    /// The same divisor for a surface whose device class hasn't been resolved yet.
    @MainActor
    func freetypeRelativeFontSize(surface: CGSize) -> Int {
        freetypeRelativeFontSize(surface: surface, metrics: .forSurface(surface))
    }

    /// Floor for the divisor: below ~4 the cue is a quarter of the picture tall, which is
    /// a broken render rather than a large one — and 0 is freetype's "Auto", which is not
    /// "unscaled" but its own baked-in 6.25 (an em of 1/16th of the output height), i.e.
    /// exactly the oversize this whole path exists to fix.
    static let freetypeRelativeFontSizeFloor = 4

    /// The user's overlay style expressed as the renderer's selective override,
    /// with the caller-computed font scale, the em the cue renders at as a
    /// fraction of the script canvas, and the tuned rest position as script-unit
    /// margins. Border and shadow ride along as fractions of that em; the
    /// renderer turns them into script units.
    ///
    /// The family stays the design bucket's own mapping, where the sans bucket
    /// has no libass name override — the synthesized script already names that
    /// family in its style.
    func rendererOverride(
        fontScale: Double,
        emHeightRatio: Double? = nil,
        shadowAlpha: Double? = nil,
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
    /// real family name, which is what the CJK font plan is built around.
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
