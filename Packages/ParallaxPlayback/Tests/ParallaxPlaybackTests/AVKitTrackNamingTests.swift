import Foundation
import Testing
@testable import ParallaxPlayback

@Suite("AVKitTrackNaming")
struct AVKitTrackNamingTests {
    private let en = Locale(identifier: "en_US")

    @Test("keeps a meaningful displayName verbatim")
    func keepsMeaningfulName() {
        let name = AVKitTrackNaming.resolvedName(
            displayName: "Director Commentary",
            languageCode: "en",
            kind: .audio,
            ordinal: 1,
            locale: en
        )
        #expect(name == "Director Commentary")
    }

    @Test("falls back to a localized language name when displayName is the Unknown placeholder")
    func languageFallbackForUnknownPlaceholder() {
        #expect(
            AVKitTrackNaming.resolvedName(
                displayName: "Unknown", languageCode: "en", kind: .audio, ordinal: 1, locale: en
            ) == "English"
        )
        #expect(
            AVKitTrackNaming.resolvedName(
                displayName: "", languageCode: "ja", kind: .subtitle, ordinal: 2, locale: en
            ) == "Japanese"
        )
    }

    @Test("falls back to an ordinal label when neither name nor language is usable")
    func ordinalFallback() {
        #expect(
            AVKitTrackNaming.resolvedName(
                displayName: "Unknown", languageCode: "und", kind: .audio, ordinal: 1, locale: en
            ) == "Audio 1"
        )
        #expect(
            AVKitTrackNaming.resolvedName(
                displayName: "", languageCode: nil, kind: .subtitle, ordinal: 3, locale: en
            ) == "Subtitle 3"
        )
    }

    @Test("treats whitespace-only and undetermined codes as non-meaningful")
    func genericDetection() {
        #expect(AVKitTrackNaming.isGenericPlaceholder("unknown"))
        #expect(AVKitTrackNaming.isGenericPlaceholder("UNKNOWN"))
        #expect(!AVKitTrackNaming.isGenericPlaceholder("English"))
        #expect(AVKitTrackNaming.localizedLanguageName("und", locale: en) == nil)
        #expect(AVKitTrackNaming.localizedLanguageName("en", locale: en) == "English")
    }
}
