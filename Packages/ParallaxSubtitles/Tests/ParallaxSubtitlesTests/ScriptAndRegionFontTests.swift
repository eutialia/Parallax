import CoreGraphics
import Foundation
import ParallaxSubtitles
import Testing

/// Which bundled face draws each run of a converted line. A missing glyph and a glyph from
/// the wrong region's face are both valid renders, so every case compares against a drawing
/// whose face is not in doubt: the missing-glyph box (U+E000, which no face has), or `次繁`
/// drawn alone in a track whose language tag decides its face. 次 and 繁 differ between all
/// four CJK regions.
@Suite("Fonts per script and region")
struct ScriptAndRegionFontTests {
    static let families = [SubtitleFontBundle.sansFamily, SubtitleFontBundle.serifFamily, SubtitleFontBundle.serifCueFamily]

    /// Where a top-left-anchored line's first two CJK glyphs fall on a 1280x720 canvas.
    static let firstTwoGlyphs = 30..<100

    /// `次繁` alone, top-left, in a track tagged `hint`: the face that tag names.
    static func reference(_ hint: String, fontFamily: String = SubtitleRenderer.standardFontFamily, twoLines: Bool = false) async throws -> Drawing {
        try await drawing(of: "regions-ref.srt", at: twoLines ? 2.5 : 1.5, languageHint: hint, fontFamily: fontFamily)
    }

    static func firstGlyphs(of path: String, at seconds: Double, languageHint: String?, fontFamily: String = SubtitleRenderer.standardFontFamily) async throws -> [UInt32] {
        try await drawing(of: path, at: seconds, languageHint: languageHint, fontFamily: fontFamily).columns(firstTwoGlyphs)
    }

    /// `scripts.srt` holds one glyph a cue, two or more per script the bundle serves, its
    /// symbols, and last the missing-glyph box.
    @Test("every script the bundle serves draws its letters, not the missing-glyph box, in Sans and in Serif")
    func everyScriptDraws() async throws {
        let glyphs = try #require(String(data: try fixture("scripts.srt"), encoding: .utf8))
            .components(separatedBy: "\n\n").filter { !$0.isEmpty }
            .map { $0.components(separatedBy: "\n")[2] }
        var byFamily: [[Drawing]] = []
        for family in Self.families {
            let subtitle = try await loaded("scripts.srt", fontFamily: family)
            let drawn = try await glyphs.indices.asyncMap { try await subtitle.drawing(at: Double($0) + 1.5) }
            let missing = try #require(drawn.last)
            for (index, glyph) in glyphs.dropLast().enumerated() {
                #expect(drawn[index] != missing, "\(glyph) draws the missing-glyph box in \(family)")
                for other in (index + 1)..<(glyphs.count - 1) where drawn[index] == drawn[other] {
                    Issue.record("\(glyph) and \(glyphs[other]) draw alike in \(family)")
                }
            }
            byFamily.append(drawn)
        }
        for (index, glyph) in glyphs.dropLast().enumerated() {
            #expect(byFamily[0][index] != byFamily[1][index], "\(glyph) draws the same in Sans and Serif")
        }
    }

    /// `regions-zh.srt`: a kana, a hangul, a simplified and a traditional line, each opening
    /// with 次繁 at the top left.
    @Test("a line written in kana, hangul, simplified or traditional characters draws from that region's face whatever the track's Chinese default", arguments: [
        (1, "ja"), (2, "ko"), (3, "zh-Hans"), (4, "zh-Hant"),
    ])
    func decisiveLinesTakeTheirRegion(second: Int, region: String) async throws {
        let expected = try await Self.reference(region).columns(Self.firstTwoGlyphs)
        for track in ["zh-Hans", "zh-Hant"] {
            let drawn = try await Self.firstGlyphs(of: "regions-zh.srt", at: Double(second) + 0.5, languageHint: track)
            #expect(drawn == expected, "line \(second) in a \(track) track")
        }
    }

    @Test("in a Japanese or Korean track, a kanji-only line draws from the track's face", arguments: [
        ("japanese-kanji.srt", "ja", 3), ("japanese-kanji.srt", "ja", 4), ("korean-hanja.srt", "ko", 2),
    ])
    func hanOnlyLinesKeepTheTrackFace(path: String, track: String, second: Int) async throws {
        let drawn = try await Self.firstGlyphs(of: path, at: Double(second) + 0.5, languageHint: track)
        #expect(drawn == (try await Self.reference(track).columns(Self.firstTwoGlyphs)))
    }

    @Test("a Chinese line with an interpunct or a prolonged-sound mark still draws from the Chinese face", arguments: [1, 2])
    func transliterationMarksStayChinese(second: Int) async throws {
        let drawn = try await Self.firstGlyphs(of: "interpunct.srt", at: Double(second) + 0.5, languageHint: "zh-Hans")
        #expect(drawn == (try await Self.reference("zh-Hans").columns(Self.firstTwoGlyphs)))
    }

    /// `punctuation.srt`: 「」, two missing-glyph boxes, Hello.
    @Test("in a CJK track, a line of only CJK punctuation draws from the track's face and a Latin line from the Latin face")
    func punctuationAndLatinInACJKTrack() async throws {
        let subtitle = try await loaded("punctuation.srt", languageHint: "zh-Hant")
        let brackets = try await subtitle.drawing(at: 1.5)

        #expect(brackets != (try await subtitle.drawing(at: 2.5)), "「」 draws the missing-glyph box")
        #expect(brackets == (try await drawing(of: "punctuation.srt", at: 1.5, languageHint: "ja")))
        #expect(try await subtitle.drawing(at: 3.5) == (try await drawing(of: "latin-only.srt", at: 1.5)))
    }

    /// `han-only.srt` opens with 次繁, Han that does not say which Chinese it is.
    @Test("a track's language tag decides which face its Han-only lines take, and a tag that names no script draws as if untagged", arguments: [
        ["ja", "jpn"], ["ko", "kor"], ["zh-Hant", "zh-TW", "chi-HK"], ["zh-Hans", "zh-CN"],
    ])
    func languageTagsPickTheFace(tags: [String]) async throws {
        let drawn = try await tags.asyncMap { try await drawing(of: "han-only.srt", at: 1.5, languageHint: $0) }
        #expect(Set(drawn.indices.map { drawn[$0] == drawn[0] }) == [true], "\(tags) draw differently")

        for other in [["ja"], ["ko"], ["zh-Hant"], ["zh-Hans"]] where !tags.contains(other[0]) {
            #expect(drawn[0] != (try await drawing(of: "han-only.srt", at: 1.5, languageHint: other[0])), "\(tags[0]) draws like \(other[0])")
        }
    }

    @Test("a tag that names no script draws as if untagged", arguments: ["zh", "en", "zh-mong"])
    func scriptlessTagsDrawAsUntagged(tag: String) async throws {
        #expect(try await drawing(of: "han-only.srt", at: 1.5, languageHint: tag) == (try await drawing(of: "han-only.srt", at: 1.5)))
    }

    @Test("without a tag, kanji lines in a track with kana draw from the Japanese face, and a Han-only track draws from the face its lines vote for")
    func untaggedTracksDecideByContent() async throws {
        let japanese = try await Self.firstGlyphs(of: "japanese-kanji.srt", at: 3.5, languageHint: nil)
        #expect(japanese == (try await Self.reference("ja").columns(Self.firstTwoGlyphs)))

        #expect(try await drawing(of: "han-only.srt", at: 1.5) == (try await drawing(of: "han-only.srt", at: 1.5, languageHint: "zh-Hans")))
        #expect(try await drawing(of: "han-only-traditional.srt", at: 1.5) == (try await drawing(of: "han-only.srt", at: 1.5, languageHint: "zh-Hant")))
    }

    @Test("with the Serif style chosen, Chinese and Japanese lines draw from the serif CJK faces", arguments: [
        (1, "ja"), (3, "zh-Hans"), (4, "zh-Hant"),
    ])
    func serifStyleTakesSerifCJK(second: Int, region: String) async throws {
        let serif = SubtitleFontBundle.serifCueFamily
        let drawn = try await Self.firstGlyphs(of: "regions-zh.srt", at: Double(second) + 0.5, languageHint: "zh-Hans", fontFamily: serif)

        #expect(drawn == (try await Self.reference(region, fontFamily: serif).columns(Self.firstTwoGlyphs)))
        #expect(drawn == (try await Self.reference(region, fontFamily: SubtitleFontBundle.serifFamily).columns(Self.firstTwoGlyphs)))
        #expect(drawn != (try await Self.reference(region).columns(Self.firstTwoGlyphs)))
    }

    /// Cue 5 of `regions-zh.srt`: 次繁 opening a simplified line, then 次繁 opening a kana line.
    @Test("each line of a two-line cue draws from its own language's face")
    func eachLineTakesItsOwnFace() async throws {
        let drawn = try await drawing(of: "regions-zh.srt", at: 5.5, languageHint: "zh-Hans")
        let chinese = try await Self.reference("zh-Hans", twoLines: true)
        let japanese = try await Self.reference("ja", twoLines: true)
        let middle = Int(try #require(chinese.ink).midY)
        let top = 0..<middle
        let bottom = middle..<Int(hdCanvas.height)

        #expect(drawn.columns(Self.firstTwoGlyphs, rows: top) == chinese.columns(Self.firstTwoGlyphs, rows: top))
        #expect(drawn.columns(Self.firstTwoGlyphs, rows: bottom) == japanese.columns(Self.firstTwoGlyphs, rows: bottom))
    }

    /// `closers.srt`: 简体 ABC and ♪ La la la, anchored top right, so the Latin text that
    /// follows the CJK run or the symbol is the part at the right margin. The mixed line sits
    /// on a different baseline, so the text is compared column by column, by how much ink each
    /// column holds.
    @Test("text after a CJK run or a symbol follows the font style I pick", arguments: [1, 3])
    func textAfterARunFollowsMyStyle(second: Int) async throws {
        var profiles: [[Int]] = []
        for family in [SubtitleFontBundle.sansFamily, SubtitleFontBundle.serifCueFamily] {
            let style = SubtitleStyleOverride(fontFamily: family)
            let line = try await drawing(of: "closers.srt", at: Double(second) + 0.5, style: style)
            let alone = try await drawing(of: "closers.srt", at: Double(second) + 1.5, style: style)
            let columns = (Int(try #require(alone.ink).minX) - 4)..<Int(hdCanvas.width)
            let expected = alone.inkPerColumn(columns)
            let drawn = line.inkPerColumn(columns)
            let difference = zip(drawn, expected).map { abs($0 - $1) }.reduce(0, +)
            #expect(drawn.prefix(4).allSatisfy { $0 == 0 }, "in \(family) the run reaches into the text after it")
            #expect(difference * 100 <= expected.reduce(0, +), "in \(family) the text after the run differs from the text alone by \(difference)")
            profiles.append(expected)
        }
        #expect(profiles[0] != profiles[1])
    }

    /// `cjk-em.srt`: 字字字字. A CJK face's full-width advance is one em, so four of them
    /// span four Latin ems when the run is sized to the Latin text.
    @Test("a CJK run draws at the em size of the Latin text around it", arguments: [
        (SubtitleFontBundle.sansFamily, 0.02), (SubtitleFontBundle.serifFamily, 0.03),
    ])
    func cjkRunMatchesTheLatinEm(family: String, tolerance: Double) async throws {
        let width = try #require(try await drawing(of: "cjk-em.srt", at: 1.5, fontFamily: family).ink).width
        let em = hdCanvas.height * SubtitleRenderer.convertedScriptFontFraction / SubtitleFontMetrics.emBoxFactor(forFamily: family)

        #expect(abs(width / (4 * em) - 1) < tolerance, "four glyphs span \(width) px against an em of \(em)")
    }

    @Test("Chinese, Japanese and Korean lines of the same length draw the same width")
    func regionsDrawTheSameWidth() async throws {
        let widths = try await ["ja", "ko", "zh-Hans", "zh-Hant"].asyncMap {
            try #require(try await drawing(of: "cjk-em.srt", at: 1.5, languageHint: $0).ink).width
        }
        #expect((widths.max() ?? 0) - (widths.min() ?? 0) <= 1, "\(widths)")
    }

    /// The claim is a 4.2% difference, so the canvas is 1440 lines: a pixel of quantization
    /// is then a quarter of the tolerance.
    @Test("switching between Sans and Serif changes CJK text width by exactly the two Latin faces' em-box ratio")
    func designsDifferByTheirEmBoxRatio() async throws {
        let canvas = CGSize(width: 2560, height: 1440)
        let sans = try await drawing(of: "cjk-em.srt", at: 1.5, fontFamily: SubtitleFontBundle.sansFamily, canvas: canvas).frame.imageRect
        let serif = try await drawing(of: "cjk-em.srt", at: 1.5, fontFamily: SubtitleFontBundle.serifFamily, canvas: canvas).frame.imageRect

        #expect(abs(serif.width / sans.width - 1.519 / 1.458) < 0.01, "\(serif) \(sans)")
    }

    /// A CJK face's em dash is full width, so a mark routed off the Latin face shows.
    @Test("guillemets, dashes and middle dots in a Chinese track draw from the Latin face")
    func latinPunctuationStaysLatin() async throws {
        #expect(try await drawing(of: "symbols-zh.srt", at: 2.5, languageHint: "zh-Hans") == (try await drawing(of: "symbols-latin.srt", at: 1.5)))
    }

    /// libass synthesizes bold only when the requested weight beats the face's own, so one
    /// style-level bold leaves the SemiBold Latin as drawn and thickens the Regular CJK face.
    @Test("with the Serif style's bold, Japanese text draws heavier and Latin text keeps SemiBold's weight")
    func serifBoldThickensOnlyRegularFaces() async throws {
        func fill(at seconds: Double, bold: Bool) async throws -> Double {
            Double(try await drawing(
                of: "bold.srt", at: seconds, languageHint: "ja", fontFamily: SubtitleFontBundle.serifCueFamily,
                style: SubtitleStyleOverride(bold: bold)
            ).fillCount)
        }
        let japanese = (plain: try await fill(at: 1.5, bold: false), bold: try await fill(at: 1.5, bold: true))
        let latin = (plain: try await fill(at: 2.5, bold: false), bold: try await fill(at: 2.5, bold: true))

        #expect(japanese.plain > 0 && japanese.bold >= japanese.plain * 1.1, "\(japanese)")
        #expect(latin.plain > 0 && latin.bold <= latin.plain * 1.03, "\(latin)")
    }
}

extension Drawing {
    /// The summed alpha of each canvas column in `columns`.
    func inkPerColumn(_ columns: Range<Int>) -> [Int] {
        columns.map { x in (0..<Int(frame.canvasSize.height)).reduce(0) { $0 + Int(pixel(x: x, y: $1).alpha) } }
    }
}
