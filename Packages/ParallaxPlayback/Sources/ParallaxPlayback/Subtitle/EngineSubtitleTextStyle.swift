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
/// - **`freetype-bold`** — bool, sets `STYLE_BOLD` on the default style. The module
///   emboldens synthetically when the selected face is not itself bold, which is how the
///   pan-CJK Regular the serif design points at reaches the client renderer's serif
///   weight. Bool options take the `--opt`/`--no-opt` form, and the negative is emitted
///   rather than omitted so the array stays a fixed shape.
/// - **`freetype-outline-thickness`** — int 0…50 read as a PERCENTAGE of the live font
///   size (`radius = fontSize * clamp(value/100, 0, 0.5)`). The None/Thin/Normal/Thick
///   labels in the option table are a UI hint, not the type. `STYLE_OUTLINE` is always
///   set, so thickness is the only knob: `0` — not a flag — is how the ring is turned
///   off for the box. The unit is a whole percent of the em, so `percent(_:)` quantizes
///   the ratio to one — a retune to 3.5% would round here.
/// - **`freetype-shadow-distance`** — float 0…1, a fraction of the font size along
///   `freetype-shadow-angle`. Zero here, with the shadow opacity at zero: the
///   canonical look is the ring alone.
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
    /// opaque black panel, with the ring off (a box carries its own contrast).
    /// It is not pixel-identical — freetype's box has no padding control, where libass
    /// reuses the outline width as one — but it reads as the same choice.
    public var freetypeSettings: [String] {
        let boxed = style.background == .opaqueBox
        return [
            "freetype-rel-fontsize=\(relativeFontSize)",
            style.fontDesign == .serif ? "freetype-bold" : "no-freetype-bold",
            "freetype-color=\(style.foreground.rgb24)",
            "freetype-opacity=\(Self.byte(style.foreground.alpha))",
            // The canonical ring: opaque black at the canonical fraction of the em,
            // thickness zero being how the box turns it off.
            "freetype-outline-color=0",
            "freetype-outline-opacity=255",
            "freetype-outline-thickness=\(boxed ? 0 : Self.percent(SubtitleStyle.outlineWidthRatio))",
            // No shadow on any renderer.
            "freetype-shadow-opacity=0",
            "freetype-shadow-distance=0",
            // Black, matching the client renderer's `BackColour` for a boxed cue.
            "freetype-background-color=0",
            "freetype-background-opacity=\(boxed ? 255 : 0)",
        ]
    }

    /// 0…1 → the module's 0…255 opacity byte.
    static func byte(_ unit: Double) -> Int {
        min(255, max(0, Int((unit * 255).rounded())))
    }

    /// An em fraction → `freetype-outline-thickness`. The module's unit is a whole
    /// percent of the live font size, so the ratio is quantized to one here (a retune
    /// to 3.5% would round), clamped to the 0…50 the option table accepts.
    static func percent(_ ratio: Double) -> Int {
        min(50, max(0, Int((ratio * 100).rounded())))
    }
}
