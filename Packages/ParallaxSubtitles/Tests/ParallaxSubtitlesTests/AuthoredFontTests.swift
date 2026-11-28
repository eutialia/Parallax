import CoreGraphics
import Foundation
import ParallaxSubtitles
import Testing

/// An authored ASS file names fonts the bundle does not ship. Each one is drawn from the
/// bundled face that keeps the author's intent: the serif or sans design, the region of a
/// CJK line, the script of a run.
@Suite("Authored fonts")
struct AuthoredFontTests {
    /// Where a top-left-anchored authored line's first two CJK glyphs fall, short of the third, on a 1280x720 canvas.
    static let firstTwoGlyphs = 0..<140

    /// `authored-zh.ass`, a SimHei track: cue 3 opens 次繁 on a simplified line, cue 4 on a
    /// Japanese one, cue 5 is Thai, cue 6 the missing-glyph box.
    @Test("in an authored Chinese track, a Japanese line draws from the Japanese face and a Thai line from the Thai face")
    func divergentLinesTakeTheirFace() async throws {
        let track = try await loaded("authored-zh.ass", languageHint: "zh-Hans")
        let simplified = try await track.drawing(at: 3.5).columns(Self.firstTwoGlyphs)
        let japanese = try await track.drawing(at: 4.5)

        #expect(japanese == (try await drawing(of: "authored-zh.ass", at: 4.5, languageHint: "ja")))
        #expect(japanese.columns(Self.firstTwoGlyphs) != simplified)
        #expect(try await track.drawing(at: 5.5) != (try await track.drawing(at: 6.5)))
    }

    /// `authored-font-names.ass`: one style per author font name, each drawing the same word,
    /// then the word in Noto Sans and in Noto Serif.
    @Test("an authored style draws in Serif when its font name means a serif face, and in Sans otherwise", arguments: [
        ("Arial", false), ("MS Sans Serif", false), ("Comic Sans MS", false), ("Flaming Text", false),
        ("Microsoft YaHei", false), ("微軟正黑體", false), ("FZLanTingHei", false), ("SimHei", false),
        ("MS PGothic", false), ("方正准圆_GBK", false), ("PingFang SC", false), ("DFKai-SB", false),
        ("MS Mincho", true), ("ＭＳ 明朝", true), ("Hiragino Mincho ProN", true), ("Noto Serif CJK", true),
        ("Times New Roman", true), ("SimSun", true), ("NSimSun", true), ("STSong", true),
        ("PMingLiU", true), ("宋体", true), ("細明體", true),
    ])
    func authoredNameKeepsItsDesign(name: String, serif: Bool) async throws {
        let names = try #require(String(data: try fixture("authored-font-names.ass"), encoding: .utf8))
            .components(separatedBy: "\n").filter { $0.hasPrefix("Style: Name") }
            .map { $0.components(separatedBy: ",")[1] }
        let cue = try #require(names.firstIndex(of: name)) + 1
        let track = try await loaded("authored-font-names.ass")
        let drawn = try await track.drawing(at: Double(cue) + 0.5)
        let sans = try await track.drawing(at: 24.5)
        let serifReference = try await track.drawing(at: 25.5)

        #expect(drawn == (serif ? serifReference : sans))
        #expect(drawn != (serif ? sans : serifReference))
    }

    /// `authored-inline-fn.ass`: 字幕 set in Mincho inside an Arial style, the same in a Mincho
    /// style with 测试 switched to Arial, and the line all in Arial.
    @Test("an authored inline font change keeps its serif intent")
    func inlineFontChangeKeepsItsDesign() async throws {
        let track = try await loaded("authored-inline-fn.ass", languageHint: "zh-Hans")
        let inlineMincho = try await track.drawing(at: 1.5)

        #expect(inlineMincho == (try await track.drawing(at: 2.5)))
        #expect(inlineMincho != (try await track.drawing(at: 3.5)))
    }

    /// `authored-serif-zh.ass`, a Mincho track whose cue 3 opens 次繁 on a Japanese line.
    @Test("in an authored serif Chinese track, a Japanese line draws from the Japanese serif face")
    func serifTrackKeepsSerifForJapanese() async throws {
        let drawn = try await drawing(of: "authored-serif-zh.ass", at: 3.5, languageHint: "zh-Hans")

        #expect(drawn == (try await drawing(of: "authored-serif-zh.ass", at: 3.5, languageHint: "ja")))
        #expect(drawn.columns(Self.firstTwoGlyphs) != (try await drawing(of: "authored-zh.ass", at: 4.5, languageHint: "ja")).columns(Self.firstTwoGlyphs))
    }

    /// `crlf-reordered.ass` is `lf-reordered.ass` with CRLF endings: a Style line whose Format
    /// puts Name second and Fontname last, naming `@DFKai-SB`, then a three-glyph kana line
    /// and three missing-glyph boxes, which is what the kana draws as when no face has it.
    @Test("a CRLF authored script with reordered Format columns draws its lines from the bundled faces")
    func crlfReorderedScriptDraws() async throws {
        let crlf = try await loaded("crlf-reordered.ass", languageHint: "zh-Hans")
        let line = try await crlf.drawing(at: 1.5)

        #expect(line == (try await drawing(of: "lf-reordered.ass", at: 1.5, languageHint: "ja")))
        #expect(line != (try await crlf.drawing(at: 2.5)))
    }

    /// `vertical.ass`, a cue a second, each a flat stroke: 一 in a style named DFKai-SB, in one
    /// named @DFKai-SB, and after an inline @MS Mincho; the Hangul ㅡ, which a Chinese track
    /// draws from the Korean face, in each of the two styles; ㅡ一 after an inline @SimHei;
    /// and 一 in the @ style after an inline SimHei.
    @Test("a font name that starts with @ draws East Asian glyphs turned a quarter turn: as a style's font, as an inline font, on a run that takes another face, and on the text after that run; an inline font without the @ draws them upright")
    func verticalFontNamesTurnGlyphs() async throws {
        let subtitle = try await loaded("vertical.ass", languageHint: "zh-Hans")
        let inks = try await (1...7).asyncMap { try #require(try await subtitle.drawing(at: Double($0) + 0.5).ink) }
        func flat(_ ink: CGRect) -> Bool { ink.width > ink.height * 3 }
        func tall(_ ink: CGRect) -> Bool { ink.height > ink.width * 3 }

        #expect(flat(inks[0]), "upright style: \(inks[0])")
        #expect(tall(inks[1]), "@ style: \(inks[1])")
        #expect(tall(inks[2]), "inline @ font: \(inks[2])")
        #expect(flat(inks[3]), "Hangul, upright style: \(inks[3])")
        #expect(tall(inks[4]), "Hangul, @ style: \(inks[4])")
        #expect(inks[5].height > inks[0].height * 4 && inks[5].width > inks[1].width * 4, "two turned strokes side by side: \(inks[5])")
        #expect(flat(inks[6]), "inline font without @ in the @ style: \(inks[6])")
    }

    /// `authored-zh.ass` cues 7 and 8 use an Open Sans and a Times New Roman style;
    /// `authored-latin.ass` is the same two lines with no Chinese in the track.
    @Test("in an authored Chinese track, a style used only by English lines draws them from the Latin face, keeping its serif intent", arguments: [
        (7.5, 1.5), (8.5, 2.5),
    ])
    func latinStyleInAChineseTrack(inTrack: Double, alone: Double) async throws {
        let drawn = try await drawing(of: "authored-zh.ass", at: inTrack, languageHint: "zh-Hans")

        #expect(drawn == (try await drawing(of: "authored-latin.ass", at: alone)))
    }

    /// `authored-restore.ass`, a Mincho style: `English ภาษาไทย English` after a Times New
    /// Roman change, with no change, after an Arial change and with Arial written again
    /// before the last word; then `ภาษาไทย ok` after a bare reset and with nothing before it.
    @Test("after a Thai run, the rest of an authored line keeps the author's own font change, or the style's font after a bare reset")
    func authoredFontRestoredAfterARun() async throws {
        let track = try await loaded("authored-restore.ass")
        let lines = try await (1...6).asyncMap { try await track.drawing(at: Double($0) + 0.5) }

        #expect(lines[0] == lines[1])
        #expect(lines[2] == lines[3])
        #expect(lines[0] != lines[2])
        #expect(lines[4] == lines[5])
    }

    /// `authored-backslash.ass`, an Arial style: `\ภาษาไทย/`, `/ภาษาไทย/`, and `\/`.
    @Test("an authored line with a backslash before Thai text draws the backslash and the Thai, not the font tag")
    func backslashBeforeThaiDraws() async throws {
        let track = try await loaded("authored-backslash.ass")
        let backslashed = try #require(try await track.drawing(at: 1.5).ink)
        let slashed = try #require(try await track.drawing(at: 2.5).ink)

        #expect(abs(backslashed.width / slashed.width - 1) < 0.3, "\(backslashed) against \(slashed)")
        #expect(try await track.drawing(at: 3.5).ink != nil)
    }
}
