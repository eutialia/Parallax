import Foundation
import ParallaxCore
import ParallaxCoreTestSupport
import ParallaxFileBrowse
import Testing

/// Labels as subtitle filenames carry them: language codes, fansub combos, qualifiers and
/// release words, joined by whatever separators the uploader used.
@Suite("Subtitle labels")
struct SubtitleLabelInfoProperties {

    private static let cases = 500
    private static let separators = Array(" ._+&[](){}")
    private static let tokens = [
        "en", "eng", "english", "ja", "jp", "zh", "chs", "cht", "sc", "tc", "big5", "ko", "fr", "fre", "de", "ger",
        "swe", "pol", "cze", "sv", "jptc", "jpsc", "big5gb", "sdh", "cc", "hi", "forced", "signs", "songs",
        "commentary", "comm", "en-gb", "zh-hant", "zh-tw", "sv-se", "por-br", "sc-team", "hans", "hant",
        "sweetsub", "ep12", "default", "raw", "v2",
    ]

    private static func label(_ random: inout SeededGenerator) -> [String] {
        (0..<Int.random(in: 1...5, using: &random)).map { _ in tokens.randomElement(using: &random)! }
    }

    private static func joined(_ parts: [String], _ random: inout SeededGenerator) -> String {
        parts.map { $0 + String(separators.randomElement(using: &random)!) }.joined()
    }

    @Test("a label reads the same whatever its letter case and whichever separators join its tags")
    func caseAndSeparatorsDoNotMatter() {
        var random = SeededGenerator(seed: 0x6C_6162)
        for run in 0..<Self.cases {
            let parts = Self.label(&random)
            let plain = parts.joined(separator: ".")
            let written = String(Self.joined(parts, &random).map {
                Bool.random(using: &random) ? Character($0.uppercased()) : $0
            })

            #expect(SubtitleLabelInfo(label: written) == SubtitleLabelInfo(label: plain), "run \(run): \(written) vs \(plain)")
        }
    }

    @Test("a label names each language once, and reads SDH and forced wherever they sit")
    func languagesOnceFlagsAnywhere() {
        var random = SeededGenerator(seed: 0x66_6C67)
        for run in 0..<Self.cases {
            let parts = Self.label(&random)
            let info = SubtitleLabelInfo(label: parts.joined(separator: "."))
            let shuffled = SubtitleLabelInfo(label: parts.shuffled(using: &random).joined(separator: "."))

            #expect(Set(info.languageTags).count == info.languageTags.count, "run \(run): \(parts)")
            #expect(shuffled.isSDH == info.isSDH, "run \(run): \(parts)")
            #expect(shuffled.isForced == info.isForced, "run \(run): \(parts)")
        }
    }

    @Test("a label shows as written only when it names no language and no content")
    func writtenNameOnlyWithoutLanguageOrContent() {
        var random = SeededGenerator(seed: 0x6E_616D)
        for run in 0..<Self.cases {
            let label = Self.label(&random).joined(separator: ".")
            let info = SubtitleLabelInfo(label: label)
            #expect(info.languageTags.allSatisfy { TrackDisplay.languageName($0) != nil }, "run \(run): \(label)")

            let named = info.displayName(fallback: label) != label

            #expect(named == !(info.languageTags.isEmpty && info.descriptors.isEmpty), "run \(run): \(label)")
        }
    }
}
