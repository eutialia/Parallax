import Foundation
import ParallaxCoreTestSupport
import Testing
@testable import ParallaxJellyfin

/// The subtitle language saved to the server, from a picked track's tag in whichever spelling
/// the track carried.
@Suite("Saved subtitle language")
struct JellyfinLanguageTagProperties {

    private static let cases = 500
    private static let cultureRows = ["zh-CN", "zh-Hans", "zh-TW", "zh-Hant", "zh-HK", "pt-BR", "pt-PT", "fr-CA", "es-419"]
    private static let tags = cultureRows + [
        "en", "eng", "en-US", "en-GB", "fr", "fra", "fre", "fr-FR", "de", "deu", "ger", "de-AT", "zh", "zho", "chi",
        "zh-SG", "ja", "jpn", "ja-JP", "pt", "por", "es", "spa", "es-MX", "sv", "swe", "sv-SE", "cs", "ces", "cze",
    ]

    private static func respelled(_ tag: String, _ random: inout SeededGenerator) -> String {
        String(tag.map { character -> Character in
            if character == "-" { return Bool.random(using: &random) ? "_" : "-" }
            return Bool.random(using: &random) ? Character(character.uppercased()) : Character(character.lowercased())
        })
    }

    @Test("a tag saves the same whatever its letter case and whether its parts are joined by - or _")
    func spellingDoesNotMatter() {
        var random = SeededGenerator(seed: 0x74_6167)
        for run in 0..<Self.cases {
            let tag = Self.tags.randomElement(using: &random)!
            let written = Self.respelled(tag, &random)

            #expect(JellyfinLanguageTag.preferenceValue(for: written) == JellyfinLanguageTag.preferenceValue(for: tag),
                    "run \(run): \(written) vs \(tag)")
        }
    }

    @Test("a tag saves as one of the culture rows the server matches exactly, else as a three-letter code, and saving the saved value again changes nothing")
    func savesAsTheServersSpelling() {
        var random = SeededGenerator(seed: 0x72_6F77)
        for run in 0..<Self.cases {
            let tag = Self.respelled(Self.tags.randomElement(using: &random)!, &random)
            let saved = JellyfinLanguageTag.preferenceValue(for: tag)

            let isRow = saved.map(Self.cultureRows.contains) ?? false
            let isAlpha3 = saved.map { $0.count == 3 && $0.allSatisfy { $0.isLowercase && $0.isASCII } } ?? false
            #expect(isRow || isAlpha3, "run \(run): \(tag) saved as \(saved ?? "nil")")
            #expect(isRow == Self.cultureRows.contains { $0.lowercased() == tag.lowercased().replacing("_", with: "-") },
                    "run \(run): \(tag)")
            #expect(JellyfinLanguageTag.preferenceValue(for: saved) == saved, "run \(run): \(tag)")
        }
    }
}
