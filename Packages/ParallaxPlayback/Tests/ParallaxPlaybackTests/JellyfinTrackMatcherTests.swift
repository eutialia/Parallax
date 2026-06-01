import Foundation
import Testing
import ParallaxCore
@testable import ParallaxPlayback

@Suite("JellyfinTrackMatcher")
struct JellyfinTrackMatcherTests {
    private let en = Locale(identifier: "en_US")

    private func audioStream(index: Int, title: String?, lang: String?) -> MediaStreamInfo {
        MediaStreamInfo(
            index: index, kind: .audio, displayTitle: title, language: lang,
            codec: "truehd", channels: 8, isExternal: false, isForced: false, isDefault: true
        )
    }

    @Test("a meaningful AVFoundation name wins — server metadata is not consulted")
    func keepsMeaningfulOptionName() {
        let name = JellyfinTrackMatcher.name(
            kind: .subtitle,
            optionDisplayName: "Chinese, Traditional (Taiwan)",
            optionLanguage: "zh-TW",
            ordinal: 1,
            optionCount: 2,
            streams: [],
            defaultStreamIndex: nil,
            locale: en
        )
        #expect(name == "Chinese, Traditional (Taiwan)")
    }

    @Test("single transcoded audio with no manifest name uses the server default-index stream title")
    func unnamedSingleAudioUsesServerDefaultIndex() {
        let streams = [
            audioStream(index: 1, title: "Commentary", lang: "eng"),
            audioStream(index: 3, title: "English - TrueHD 7.1 - Default", lang: "eng"),
        ]
        let name = JellyfinTrackMatcher.name(
            kind: .audio,
            optionDisplayName: "Unknown",     // manifest carried no name
            optionLanguage: nil,              // …and no language
            ordinal: 1,
            optionCount: 1,                   // single rendition in the manifest
            streams: streams,
            defaultStreamIndex: 3,
            locale: en
        )
        // Picks index 3 (the transcoded default), strips the " - Default" noise.
        #expect(name == "English - TrueHD 7.1")
    }

    @Test("falls back to the ordinal label when no server stream matches")
    func ordinalFallbackWhenNoServerMatch() {
        let name = JellyfinTrackMatcher.name(
            kind: .audio,
            optionDisplayName: "Unknown",
            optionLanguage: nil,
            ordinal: 1,
            optionCount: 1,
            streams: [],                      // no metadata at all
            defaultStreamIndex: 3,
            locale: en
        )
        #expect(name == "Audio 1")
    }

    @Test("multiple unnamed audio options match the server stream by language")
    func multipleAudioMatchByLanguage() {
        let streams = [
            audioStream(index: 2, title: "Français", lang: "fra"),
            audioStream(index: 3, title: "English - AC3", lang: "eng"),
        ]
        let name = JellyfinTrackMatcher.name(
            kind: .audio,
            optionDisplayName: "Unknown",
            optionLanguage: "eng",
            ordinal: 2,
            optionCount: 2,                   // not a single rendition → language match
            streams: streams,
            defaultStreamIndex: nil,
            locale: en
        )
        #expect(name == "English - AC3")
    }

    @Test("language match normalizes BCP-47 'en' against ISO 639-2/T 'eng'")
    func languageMatchNormalizesAlpha2VsAlpha3() {
        let streams = [
            audioStream(index: 2, title: "Français", lang: "fra"),
            audioStream(index: 3, title: "English - DTS", lang: "eng"),
        ]
        let name = JellyfinTrackMatcher.name(
            kind: .audio,
            optionDisplayName: "Unknown",
            optionLanguage: "en",             // AVFoundation BCP-47, vs server "eng"
            ordinal: 2,
            optionCount: 2,
            streams: streams,
            defaultStreamIndex: nil,
            locale: en
        )
        // Before the alpha-2/alpha-3 normalization this missed → "Audio 2".
        #expect(name == "English - DTS")
    }

    @Test("ambiguous same-language streams (zh-Hant vs zh-Hans) are not collapsed onto one server title")
    func ambiguousLanguageDoesNotFalseMatch() {
        // Two server streams both report lang "zho" (script lives only in the title);
        // AVFoundation distinguishes them by tag. Alpha-3 normalization makes both
        // "zh-Hant" and "zho" equal, so a first-match join would label BOTH the same.
        let streams = [
            audioStream(index: 2, title: "Chinese - Traditional", lang: "zho"),
            audioStream(index: 3, title: "Chinese - Simplified", lang: "zho"),
        ]
        let name = JellyfinTrackMatcher.name(
            kind: .audio,
            optionDisplayName: "Unknown",
            optionLanguage: "zh-Hant",
            ordinal: 1,
            optionCount: 2,
            streams: streams,
            defaultStreamIndex: nil,
            locale: en
        )
        // Must NOT slap the first stream's title on; the match is ambiguous, so it
        // falls through to a language/ordinal fallback instead of a wrong rendition.
        #expect(name != "Chinese - Traditional")
        #expect(name != "Chinese - Simplified")
    }
}
