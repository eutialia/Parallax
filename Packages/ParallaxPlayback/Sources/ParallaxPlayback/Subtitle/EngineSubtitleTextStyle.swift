import Foundation

/// The user's `SubtitleStyle` in the vocabulary of VLC 3.0's *simple* freetype text
/// renderer — the module that draws an embedded SRT (or any plain `text` track) the app
/// is not rendering itself. Without it those cues come out at freetype's own defaults:
/// `STYLE_DEFAULT_REL_FONT_SIZE` 6.25, i.e. an em of 1/16th of the video output height,
/// in peak white — 1.2–1.8× the size the client renderer draws an external SRT at, and
/// the wrong colours.
///
/// Semantics verified against VLC 3.0.x (`modules/text_renderer/freetype/freetype.c`
/// option table ~L155–246, `platform_fonts.c` `ConvertToLiveSize` ~L456–478,
/// `text_layout.c` `LoadGlyphs` ~L974–984 and the shadow pen ~L1155–1169):
///
/// - **`freetype-rel-fontsize`** — int. The module stores `100/N` and computes
///   `em = outputHeight * (100/N) / 100`, so the option is a DIVISOR of the output
///   height. Relative on purpose: `freetype-fontsize` is absolute pixels and VLC renders
///   the SPU at `max(source, placed)` resolution, so an absolute size halves on a 4K
///   source. `0` is not "unscaled" — it falls back to the baked-in 6.25.
/// - **`freetype-outline-thickness`** — int 0…50 read as a PERCENTAGE of the live font
///   size (`radius = fontSize * clamp(value/100, 0, 0.5)`). The None/Thin/Normal/Thick
///   labels in the option table are a UI hint, not the type. `STYLE_OUTLINE` is always
///   set, so thickness `0` — not a flag — is how the ring is turned off, and the
///   canonical look has no ring.
/// - **`freetype-shadow-distance`** — float 0…1, a fraction of the font size along
///   `freetype-shadow-angle` (default −45°, i.e. down-right). The style offsets by the
///   same ratio on both axes, which is exactly that angle: `distance = ratio × √2`.
///   **The module cannot blur.** It offsets a hard copy of the glyph and the option
///   table carries no radius anywhere, so this path stops at a hard offset shadow —
///   as close to the canonical soft one as VLC's simple renderer goes.
/// - **opacities** (`freetype-opacity`, `-outline-opacity`, `-shadow-opacity`,
///   `-background-opacity`) — ints 0…255. **colours** (`freetype-color`,
///   `-outline-color`, `-background-color`) — 24-bit `0xRRGGBB`, alpha carried separately.
///
/// Every one of these is a libvlc **instance** setting, not a media option: the freetype
/// text renderer is created by the video output (`SpuRenderCreateAndLoadText`), whose
/// `var_Inherit` chain ends at the libvlc instance and never sees an input item's
/// variables. See `VLCKitEngine.libraryOptions(for:)`, which is what turns these into
/// `--freetype-…` arguments.
public struct EngineSubtitleTextStyle: Sendable, Hashable {
    public let style: SubtitleStyle
    /// The `:freetype-rel-fontsize` divisor: `em = videoOutputHeight / relativeFontSize`.
    /// Computed by the app, which is the only side that knows both the player surface and
    /// the per-device cue size the client renderer draws at.
    public let relativeFontSize: Int

    public init(style: SubtitleStyle, relativeFontSize: Int) {
        self.style = style
        self.relativeFontSize = relativeFontSize
    }

    /// The `freetype-*` settings, in a fixed order and always the full set — so what the
    /// engine emits is a pure function of the style rather than a shape that varies with
    /// which fields happened to be non-default.
    ///
    /// **Bare `name=value`, no sigil.** The prefix encodes the SCOPE and belongs to the
    /// caller: these are instance-scoped, so `VLCKitEngine.libraryOptions(for:)` prepends
    /// `--`. A `:` prefix would make them media options, which the freetype renderer
    /// cannot see at all (that was the defect).
    ///
    /// `.opaqueBox` mirrors what the client renderer does at libass BorderStyle 3: a fully
    /// opaque black panel, with the shadow off (a box carries its own contrast).
    /// It is not pixel-identical — freetype's box has no padding control, where libass
    /// reuses the outline width as one — but it reads as the same choice.
    public var freetypeSettings: [String] {
        let boxed = style.background == .opaqueBox
        return [
            "freetype-rel-fontsize=\(relativeFontSize)",
            "freetype-color=\(style.foreground.rgb24)",
            "freetype-opacity=\(Self.byte(style.foreground.alpha))",
            // Never drawn (opacity 0), never zero (thickness): the module strokes every
            // glyph and copies the STROKE into the shadow, not the glyph, so thickness 0
            // makes the shadow a copy of an empty shape. The invisible stroke is what the
            // shadow is made of — see `shadowSeedThicknessPercent`.
            "freetype-outline-opacity=0",
            "freetype-outline-thickness=\(boxed ? 0 : Self.shadowSeedThicknessPercent)",
            "freetype-shadow-opacity=\(boxed ? 0 : Self.byte(Self.hardShadowOpacity))",
            "freetype-shadow-distance=\(Self.distance(SubtitleStyle.shadowOffsetRatio))",
            // Black, matching the client renderer's `BackColour` for a boxed cue.
            "freetype-background-color=0",
            "freetype-background-opacity=\(boxed ? 255 : 0)",
        ]
    }

    // The shadow this path can draw is a hard copy of the glyph dilated by the stroke,
    // so these two stand in for the canonical blur and opacity, which only the client
    // renderer can honour. Chosen by eye against that renderer's halo; the offset is
    // the canonical one.

    /// Stroke thickness as the module's whole percent of the em. The stroke is the
    /// shadow's shape: dilation is the only "softness" available here, and the stroke
    /// band has to be at least half a stem wide to read as solid.
    static let shadowSeedThicknessPercent = 3
    /// Black, at this opacity — below the canonical 80% because the dilated copy carries
    /// more ink than a blurred one.
    static let hardShadowOpacity = 0.70

    /// 0…1 → the module's 0…255 opacity byte.
    static func byte(_ unit: Double) -> Int {
        min(255, max(0, Int((unit * 255).rounded())))
    }

    /// A per-axis em fraction → `freetype-shadow-distance` along the default −45° angle,
    /// where each component is `distance × sin45`. Formatted non-localized
    /// (`String(format:)` with no locale), because libvlc parses the option with `strtod`.
    static func distance(_ offsetRatio: Double) -> String {
        let hypotenuse = min(1, max(0, offsetRatio * 2.0.squareRoot()))
        return String(format: "%.4f", hypotenuse)
    }
}
