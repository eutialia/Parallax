import Foundation
import ParallaxCoreTestSupport
import Testing
@testable import ParallaxSubtitles

/// Event text as it reaches the tagger: escaped, with the author's override blocks, in every
/// script the bundle draws.
@Suite("Font tagging")
struct FontTaggingProperties {

    private static let cases = 300

    private static let plain = ["Hello", "world", "αβγ", "Привет", " ", ", ", "!", "0"]
    private static let scripts = [
        "สวัสดี", "مرحبا", "क्\u{200D}ष", "हिन्दी", "这是简体", "這是繁體", "これは", "한국어", "東京", "♪", "★",
        "\u{200E}", "\u{200F}",
    ]
    private static let markup = ["\\{", "\\}", "\\h", "\\N", "\\n", "\\\u{2060}", "{\\an8}", "{\\i1}", "{\\fnArial}", "{\\fn}"]
    private static let styleFamilies = [
        SubtitleFontBundle.sansFamily, SubtitleFontBundle.serifFamily, SubtitleFontBundle.serifCueFamily,
    ]
    private static let hints: [String?] = [nil, "ja", "ko", "zh-Hans", "zh-Hant", "en"]

    private struct Track {
        let fields: [String]
        let plan: SubtitleFontPlan
    }

    private static func track(of pieces: [String], _ random: inout SeededGenerator) -> Track {
        let fields = (0..<Int.random(in: 1...4, using: &random)).map { _ in
            (0..<Int.random(in: 1...10, using: &random)).map { _ in pieces.randomElement(using: &random)! }.joined()
        }
        return Track(
            fields: fields,
            plan: SubtitleFontPlan.build(
                lines: fields.flatMap(SubtitleFontTagger.plainLines),
                styleFamily: styleFamilies.randomElement(using: &random)!,
                languageHint: hints.randomElement(using: &random)!))
    }

    private static func blocks(of field: String) -> [String] {
        SubtitleFontTagger.tokenize(field).compactMap { if case .override(let block) = $0 { block } else { nil } }
    }

    private static func visibleText(of field: String) -> [String] {
        SubtitleFontTagger.plainLines(of: field).map { $0.replacingOccurrences(of: "\u{2060}", with: "") }
    }

    private static func inheritsItsRun(_ character: Character) -> Bool {
        switch character.unicodeScalars.first?.properties.generalCategory {
        case .nonspacingMark, .spacingMark, .enclosingMark, .format: true
        default: false
        }
    }

    /// The four things tagging may never do to a field, whichever tagger wrote `tagged`.
    private static func expectOnlyFontTagsWereAdded(to field: String, giving tagged: String, _ context: String) throws {
        let fontTag = try Regex(#"\{\\fn[^\\{}]*(\\fs[0-9.]*)?\}"#)

        #expect(visibleText(of: tagged) == visibleText(of: field), "\(context)")

        let written = blocks(of: field)
        var authored = written[...]
        let tokens = SubtitleFontTagger.tokenize(tagged)
        for (token, next) in zip(tokens, tokens.dropFirst() + [.character(" ")]) {
            switch token {
            case .override(let block) where block == authored.first:
                authored = authored.dropFirst()
            case .override(let block):
                #expect(try fontTag.wholeMatch(in: block) != nil, "\(context): added \(block)")
                // A tag that spells one of the author's blocks can't be told from it here.
                if case .character(let character) = next, !written.contains(block) {
                    #expect(!inheritsItsRun(character), "\(context): a tag splits a mark from its base")
                }
            case .character(let character):
                #expect(character != "{" && character != "}", "\(context): a bare brace")
            case .escaped, .lineBreak:
                break
            }
        }
        #expect(authored.isEmpty, "\(context): an authored block is gone")
    }

    @Test("tagging a converted line adds font tags and nothing else: the text, the author's blocks and every mark's base stay as they were")
    func convertedTaggingOnlyAddsFontTags() throws {
        var random = SeededGenerator(seed: 0x74_6167)
        for run in 0..<Self.cases {
            let track = Self.track(of: Self.plain + Self.scripts + Self.markup, &random)
            for field in track.fields {
                let tagged = SubtitleFontTagger.tagged(field, plan: track.plan, styleFontSize: 48)

                try Self.expectOnlyFontTagsWereAdded(to: field, giving: tagged, "run \(run): \(field.debugDescription) -> \(tagged.debugDescription)")
            }
        }
    }

    @Test("tagging an authored line adds font tags and nothing else")
    func authoredTaggingOnlyAddsFontTags() throws {
        var random = SeededGenerator(seed: 0x61_7574)
        for run in 0..<Self.cases {
            let track = Self.track(of: Self.plain + Self.scripts + Self.markup, &random)
            for field in track.fields {
                let tagged = SubtitleFontTagger.authoredTagged(field, plan: track.plan)

                try Self.expectOnlyFontTagsWereAdded(to: field, giving: tagged, "run \(run): \(field.debugDescription) -> \(tagged.debugDescription)")
                #expect(!tagged.contains("\\fs"), "run \(run): the author's sizes are theirs")
            }
        }
    }

    @Test("a line of Latin, Greek and Cyrillic text comes back as written")
    func styleFontTextIsLeftAlone() {
        var random = SeededGenerator(seed: 0x6C_6174)
        for run in 0..<Self.cases {
            let track = Self.track(of: Self.plain + Self.markup, &random)
            for field in track.fields {
                #expect(SubtitleFontTagger.tagged(field, plan: track.plan, styleFontSize: 48) == field, "run \(run)")
                #expect(SubtitleFontTagger.authoredTagged(field, plan: track.plan) == field, "run \(run)")
            }
        }
    }
}
