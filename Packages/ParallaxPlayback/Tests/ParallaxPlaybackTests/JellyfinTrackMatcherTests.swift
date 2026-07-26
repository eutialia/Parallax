import Foundation
import Testing
import ParallaxCore
@testable import ParallaxPlayback

@Suite("JellyfinTrackMatcher")
struct JellyfinTrackMatcherTests {
    private let en = Locale(identifier: "en_US")

    /// Codec/channels are parameters, not fixed to TrueHD: fixtures whose title said
    /// "AC3"/"DTS" while carrying TrueHD metadata made the codec axis untestable.
    private func audioStream(
        index: Int,
        title: String?,
        lang: String?,
        streamTitle: String? = nil,
        codec: String = "truehd",
        channels: Int = 8
    ) -> MediaStreamInfo {
        MediaStreamInfo(
            index: index, kind: .audio, displayTitle: title, title: streamTitle, language: lang,
            codec: codec, channels: channels, isExternal: false, isForced: false, isDefault: true
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

    /// A single transcoded rendition is identified by the server's default index, and
    /// named by LANGUAGE — codec detail belongs on the menu's secondary line, never
    /// in the primary name.
    @Test("single unnamed rendition takes the server default-index stream's clean name")
    func unnamedSingleAudioUsesServerDefaultIndex() {
        let streams = [
            audioStream(index: 1, title: "Commentary", lang: "eng", codec: "ac3", channels: 2),
            audioStream(index: 3, title: "English - TrueHD 7.1 - Default", lang: "eng"),
        ]
        let name = JellyfinTrackMatcher.name(
            kind: .audio,
            optionDisplayName: "Unknown",     // manifest carried no name…
            optionLanguage: nil,              // …and no language
            ordinal: 1,
            optionCount: 1,
            streams: streams,
            defaultStreamIndex: 3,
            locale: en
        )
        #expect(name == "English")
    }

    @Test("a stream's own title outranks its language name")
    func streamTitleWins() {
        let streams = [
            audioStream(index: 3, title: "English - AC3 - Default", lang: "eng",
                        streamTitle: "Director's Commentary", codec: "ac3", channels: 6),
        ]
        let name = JellyfinTrackMatcher.name(
            kind: .audio,
            optionDisplayName: "Unknown",
            optionLanguage: nil,
            ordinal: 1,
            optionCount: 1,
            streams: streams,
            defaultStreamIndex: 3,
            locale: en
        )
        #expect(name == "Director's Commentary")
    }

    /// The join exists so the menu's secondary line can show codec/channel detail the
    /// manifest never carries. Asserted on the joined stream's own fields — the
    /// "TrueHD · 7.1" *formatting* is ParallaxCore's `trackDetailLabel` contract.
    @Test("matchedStream returns the server stream carrying the codec detail")
    func matchedStreamCarriesDetail() throws {
        let streams = [
            audioStream(index: 2, title: "Français", lang: "fra", codec: "aac", channels: 2),
            audioStream(index: 3, title: "English - TrueHD", lang: "eng", codec: "truehd", channels: 8),
        ]
        let matched = try #require(JellyfinTrackMatcher.matchedStream(
            kind: .audio,
            optionLanguage: "en",
            optionCount: 2,
            streams: streams,
            defaultStreamIndex: nil
        ))
        #expect(matched.index == 3)
        #expect(matched.codec == "truehd")
        #expect(matched.channels == 8)
        // Detail-line wording/separator are ParallaxCore's vocabulary, not this test's.
        let codecName = try #require(TrackDisplay.audioCodecName(codec: "truehd"))
        let layout = try #require(TrackDisplay.channelLayout(8))
        #expect(matched.trackDetailLabel == "\(codecName) · \(layout)")
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

    @Test("multiple unnamed options join the server stream by language and take its title")
    func multipleAudioMatchByLanguage() {
        let streams = [
            audioStream(index: 2, title: "Français", lang: "fra", codec: "aac", channels: 2),
            audioStream(index: 3, title: "English - AC3", lang: "eng",
                        streamTitle: "Theatrical Mix", codec: "ac3", channels: 6),
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
        #expect(name == "Theatrical Mix")
    }

    /// AVFoundation yields BCP-47 (`en`, `fr`) while Jellyfin reports ISO 639-2 — often
    /// the BIBLIOGRAPHIC form (`fre`/`ger`/`chi`) that ICU does not recognize. Without
    /// `TrackLanguage`'s B→T map both of these missed and fell back to "Audio 2".
    @Test("language matching normalizes across BCP-47 / 639-2 T / 639-2 B forms", arguments: [
        ("alpha-2 vs alpha-3 T", "en", "eng", "fra", "English"),
        ("alpha-2 vs alpha-3 B", "fr", "fre", "eng", "French"),
    ] as [(String, String, String, String, String)])
    func languageMatchNormalizesCodeForms(
        label: String, optionLanguage: String, serverLang: String,
        otherLang: String, expected: String
    ) {
        let streams = [
            audioStream(index: 2, title: "Other", lang: otherLang, codec: "aac", channels: 2),
            audioStream(index: 3, title: "Target", lang: serverLang, codec: "dts", channels: 6),
        ]
        let name = JellyfinTrackMatcher.name(
            kind: .audio,
            optionDisplayName: "Unknown",
            optionLanguage: optionLanguage,
            ordinal: 2,
            optionCount: 2,
            streams: streams,
            defaultStreamIndex: nil,
            locale: en
        )
        #expect(name == expected, "\(label)")
    }

    /// Two server streams both report "zho" (script lives only in the title) while
    /// AVFoundation distinguishes them by tag. Alpha-3 normalization makes both equal,
    /// so a first-match join would label BOTH the same — the matcher must decline and
    /// let AVFoundation's script-aware naming take over.
    @Test("ambiguous same-language streams produce no match")
    func ambiguousLanguageDoesNotFalseMatch() {
        let streams = [
            audioStream(index: 2, title: "Chinese - Traditional", lang: "zho"),
            audioStream(index: 3, title: "Chinese - Simplified", lang: "zho"),
        ]
        let matched = JellyfinTrackMatcher.matchedStream(
            kind: .audio,
            optionLanguage: "zh-Hant",
            optionCount: 2,
            streams: streams,
            defaultStreamIndex: nil
        )
        #expect(matched == nil)
    }

    /// The kind filter must hold: a subtitle option can never join an audio stream just
    /// because the languages line up.
    @Test("the join never crosses audio and subtitle streams")
    func kindFilterHolds() {
        let streams = [audioStream(index: 3, title: "English", lang: "eng")]
        let matched = JellyfinTrackMatcher.matchedStream(
            kind: .subtitle,
            optionLanguage: "en",
            optionCount: 1,
            streams: streams,
            defaultStreamIndex: 3
        )
        #expect(matched == nil)
    }
}
