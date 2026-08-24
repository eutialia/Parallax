import Foundation
import Testing
import ParallaxCore
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
        // "_" is a token separator, so a script suffix arrives as its own
        // component and has to be folded back onto the language it qualifies.
        Case("zh_Hans", tags: ["zh-Hans"], display: "Chinese, Simplified"),
        Case("zh_hant", tags: ["zh-Hant"], display: "Chinese, Traditional"),
        // The look-ahead only ever eats a script token — flags stay flags.
        Case("zh_forced", tags: ["zh"], forced: true, display: "Chinese"),
        Case("zh_hi", tags: ["zh"], sdh: true, display: "Chinese"),
        // Languages outside the curated fansub table resolve through ISO 639.
        Case("swe", tags: ["sv"], display: "Swedish"),
        Case("sv", tags: ["sv"], display: "Swedish"),
        Case("pol", tags: ["pl"], display: "Polish"),
        Case("cze", tags: ["cs"], display: "Czech"),
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

    /// The same file must read the same on both transports: an SMB sidecar named
    /// `.zh_Hans.` and a Jellyfin stream tagged `zh-Hans` are one language.
    @Test("SMB label naming matches the Jellyfin-path rendering of the same tag", arguments: [
        ("zh_Hans", "zh-Hans"), ("cht", "zh-Hant"), ("swe", "sv"), ("eng", "en"),
    ] as [(String, String)])
    func namingParityWithStreamTags(label: String, streamTag: String) {
        let info = SubtitleLabelInfo(label: label)
        #expect(info.displayName(fallback: label, locale: Self.english)
                == TrackDisplay.languageName(streamTag, locale: Self.english))
    }

    /// The algorithmic ISO path is LABEL-only; the matcher's stem scan keeps the
    /// curated vocabulary so ordinary title words ("The.Mac.and.Me") can't be
    /// read as languages.
    @Test("Release-tag words ICU happens to accept never enter the matcher's vocabulary", arguments: [
        "man", "war", "new", "car", "sun", "fin", "in", "no", "to", "be",
    ])
    func matcherVocabularyStaysCurated(word: String) {
        #expect(SubtitleLabelInfo.languageTagByToken[word] == nil)
    }

    /// The matcher probes `bcp47Tag` on raw hyphenated STEM tokens, so its
    /// default (un-widened) entry must also stay curated — "man" is ISO 639-2
    /// Mandingo and "so" is Somali, but a hyphenated title word must not
    /// resolve through them.
    @Test("Hyphenated stem tokens stay out of the matcher's default bcp47 probe", arguments: [
        "man-gb", "so-so", "se-ri", "mr-dl", "war-us",
    ])
    func stemProbeStaysCurated(component: String) {
        #expect(SubtitleLabelInfo.bcp47Tag(component) == nil)
    }

    @Test("Label parsing still resolves ISO bases in hyphenated components", arguments: [
        ("sv-se", "sv"), ("por-br", "pt"),
    ] as [(String, String)])
    func widenedLabelComponents(label: String, tag: String) {
        #expect(SubtitleLabelInfo(label: label).languageTags == [tag])
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
