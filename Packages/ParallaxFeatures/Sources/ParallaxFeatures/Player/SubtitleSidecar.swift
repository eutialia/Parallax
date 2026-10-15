import Foundation
import CoreGraphics
import ParallaxPlayback
import ParallaxSubtitles

/// What the sidecar renderer was loaded with. The debug panel shows it, and the
/// style push keys off `format`: SRT/VTT carry no authored look, so the user's
/// style always applies; ASS/SSA keeps its creator's, always.
public struct SidecarSubtitleInfo: Equatable, Sendable {
    public let format: SubtitleSourceFormat
    public let byteCount: Int
}

/// What one sidecar request brought back.
public enum SubtitleFetchOutcome: Sendable {
    case data(Data)
    /// No answer in time: Jellyfin is still extracting the stream, and a later request is served
    /// from its cache.
    case notReady
    /// An error status, an empty body, or no connection.
    case rejected
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
    /// `cueSize` is the overlay's tuned cue size on this surface (`PlayerMetrics.subtitleFontSize`
    /// in the app), which is what ties the divisor to the device class.
    nonisolated public func freetypeRelativeFontSize(surface: CGSize, cueSize: CGFloat) -> Int {
        let em = cueSize * fontScale
        guard em > 0 else { return Self.freetypeRelativeFontSizeFloor }
        let videoRectHeight = min(surface.height, surface.width * 9 / 16)
        return max(Self.freetypeRelativeFontSizeFloor, Int((videoRectHeight / em).rounded()))
    }

    /// Floor for the divisor: below ~4 the cue is a quarter of the picture tall, which is
    /// a broken render rather than a large one — and 0 is freetype's "Auto", which is not
    /// "unscaled" but its own baked-in 6.25 (an em of 1/16th of the output height), i.e.
    /// exactly the oversize this whole path exists to fix.
    nonisolated public static let freetypeRelativeFontSizeFloor = 4

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

    /// The same bucket in the font bundle's vocabulary — for callers that ask the bundle
    /// for a family per SCRIPT (VLC's own renderers, which take a family name and a font
    /// directory rather than a style override).
    public var bundleDesign: SubtitleFontBundle.Design {
        switch self {
        case .sansSerif: .sans
        case .serif: .serif
        }
    }
}

/// The player's surface and the cue size the overlay draws at on it. The app measures both:
/// the cue size follows the device class, which only the app can read.
nonisolated public struct SubtitleSurface: Sendable {
    public let size: CGSize
    public let cueSize: CGFloat

    public init(size: CGSize, cueSize: CGFloat) {
        self.size = size
        self.cueSize = cueSize
    }
}

/// What VLC's own subtitle renderers are pointed at for one design: a font directory for its
/// libass, and a family name for its freetype renderer.
nonisolated public struct EngineSubtitleFonts: Sendable {
    public let directory: URL
    public let family: String

    public init(directory: URL, family: String) {
        self.directory = directory
        self.family = family
    }
}
