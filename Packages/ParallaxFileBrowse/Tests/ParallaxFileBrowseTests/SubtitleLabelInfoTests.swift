import Foundation
import Testing
@testable import ParallaxFileBrowse

/// Label → structured translation, pinned to an explicit locale so the localized
/// names don't drift with the test host. Cases cover every token class: atomic
/// languages, script-carrying fansub tags, combos, flags, descriptors, and the
/// pass-through labels that must NOT be rewritten.
@Suite("SubtitleLabelInfo")
struct SubtitleLabelInfoTests {

    private static let english = Locale(identifier: "en_US")

    struct Case: Sendable, CustomTestStringConvertible {
        let label: String
        let tags: [String]
        let sdh: Bool
        let forced: Bool
        let display: String

        init(_ label: String, tags: [String], sdh: Bool = false, forced: Bool = false, display: String) {
            self.label = label
            self.tags = tags
            self.sdh = sdh
            self.forced = forced
            self.display = display
        }

        var testDescription: String { label }
    }

    static let cases: [Case] = [
        Case("en", tags: ["en"], display: "English"),
        Case("zh.hi", tags: ["zh"], sdh: true, display: "Chinese"),
        Case("en.forced", tags: ["en"], forced: true, display: "English"),
        Case("en.sdh", tags: ["en"], sdh: true, display: "English"),
        Case("eng.cc", tags: ["en"], sdh: true, display: "English"),
        Case("chs", tags: ["zh-Hans"], display: "Chinese, Simplified"),
        Case("cht", tags: ["zh-Hant"], display: "Chinese, Traditional"),
        Case("jptc", tags: ["ja", "zh-Hant"], display: "Japanese + Chinese, Traditional"),
        Case("jpsc", tags: ["ja", "zh-Hans"], display: "Japanese + Chinese, Simplified"),
        Case("sc.jp", tags: ["zh-Hans", "ja"], display: "Chinese, Simplified + Japanese"),
        Case("en.signs songs", tags: ["en"], display: "English (Signs & Songs)"),
        Case("commentary", tags: [], display: "Commentary"),
        // Hyphenated components resolve as ONE BCP-47 unit — "gb" here is the
        // region, never the fansub Simplified-Chinese token.
        Case("en-GB", tags: ["en"], display: "English"),
        Case("zh-Hant", tags: ["zh-Hant"], display: "Chinese, Traditional"),
        Case("zh-CN", tags: ["zh-Hans"], display: "Chinese, Simplified"),
        Case("zh-TW", tags: ["zh-Hant"], display: "Chinese, Traditional"),
        // Bracketed fansub tags are unwrapped by the tokenizer.
        Case("[chs]", tags: ["zh-Hans"], display: "Chinese, Simplified"),
        // A release-group tag that merely STARTS with a language token must not
        // translate (all-or-nothing rule for hyphenated components).
        Case("sc-team", tags: [], display: "sc-team"),
        // No recognised tokens → the raw label is already the best name.
        Case("Default", tags: [], display: "Default"),
        Case("sweetsub", tags: [], display: "sweetsub"),
        Case("ep12", tags: [], display: "ep12"),
    ]

    @Test("label translation", arguments: cases)
    func translates(_ c: Case) {
        let info = SubtitleLabelInfo(label: c.label)
        #expect(info.languageTags == c.tags)
        #expect(info.isSDH == c.sdh)
        #expect(info.isForced == c.forced)
        #expect(info.displayName(fallback: c.label, locale: Self.english) == c.display)
    }

    @Test("matcher language vocabulary stays translatable")
    func matcherVocabularyCovered() {
        // Every language token the matcher can emit as (part of) a label must
        // translate — the derivation in SubtitleMatcher makes this structural,
        // but the combo table is separate; pin both.
        for combo in SubtitleLabelInfo.comboLanguageTags.keys {
            #expect(!SubtitleLabelInfo(label: combo).languageTags.isEmpty)
        }
    }
}
