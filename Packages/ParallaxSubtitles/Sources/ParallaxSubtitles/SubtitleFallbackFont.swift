import Foundation

/// The bundled last-resort subtitle font.
///
/// CoreText's fallback answer for Chinese ideographs is PingFang, whose modern
/// container FreeType cannot parse — so libass needs a font file it can always
/// open for glyphs no openable system face covers.
public enum SubtitleFallbackFont {
    /// Noto Sans CJK SC (SIL OFL 1.1) — full pan-CJK repertoire (Simplified and
    /// Traditional Han, kana, hangul) in a container FreeType parses. Handed to
    /// libass as the default font path, it is the terminal step of the per-glyph
    /// fallback chain, so it only draws when every system candidate failed.
    public static let bundledURL: URL? = Bundle.module.url(
        forResource: "NotoSansCJKsc-Regular", withExtension: "otf"
    )
}
