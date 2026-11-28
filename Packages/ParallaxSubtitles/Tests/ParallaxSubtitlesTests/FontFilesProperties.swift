import Foundation
import ParallaxCoreTestSupport
import Testing
@testable import ParallaxSubtitles

/// Which font files a track loads. libass keeps every file it is given for the life of the
/// process, so a track must load the files its families live in and no others.
@Suite("Font files for a track")
struct FontFilesProperties {

    private static let cases = 300

    private static let familiesByFile: [String: Set<String>] = Dictionary(
        uniqueKeysWithValues: SubtitleFontBundle.fileURLs.map {
            ($0.lastPathComponent, Set(SFNTFace.faces(of: $0).map(\.familyName)))
        })
    /// The families the routing can name.
    private static let shipped = Set(SubtitleFontBundle.table.values.flatMap { [$0.sans, $0.serif] } + [SubtitleFontBundle.serifCueFamily]).sorted()
    private static let strangers = ["Arial", "Comic Sans MS", "PingFang SC", "", "Noto Sans Klingon"]

    private static func families(_ random: inout SeededGenerator) -> Set<String> {
        Set((0..<Int.random(in: 0...5, using: &random)).map { _ in
            Int.random(in: 0..<3, using: &random) == 0 ? strangers.randomElement(using: &random)! : shipped.randomElement(using: &random)!
        })
    }

    private static func files(for families: Set<String>) -> Set<String> {
        Set(SubtitleFontBundle.files(forFamilies: families).map(\.lastPathComponent))
    }

    @Test("a track loads the Latin pair, a file for every shipped family it names, and at most the sans and serif file of each")
    func aTrackLoadsWhatItNames() {
        var random = SeededGenerator(seed: 0x66_696C)
        for run in 0..<Self.cases {
            let families = Self.families(&random)

            let files = Self.files(for: families)

            let named = families.intersection(Self.shipped)
            #expect(files.isSuperset(of: SubtitleFontBundle.latinFileNames), "run \(run): \(families)")
            for family in named {
                #expect(files.contains { Self.familiesByFile[$0]!.contains(family) }, "run \(run): \(family)")
            }
            #expect(files.count <= 2 + 2 * named.count, "run \(run): \(families) loaded \(files)")
        }
    }

    @Test("two sets of families load the files each loads alone, and a family nobody ships loads nothing")
    func filesAddUp() {
        var random = SeededGenerator(seed: 0x61_6464)
        for run in 0..<Self.cases {
            let one = Self.families(&random), other = Self.families(&random)

            #expect(Self.files(for: one.union(other)) == Self.files(for: one).union(Self.files(for: other)), "run \(run)")
            #expect(Self.files(for: one.union(Self.strangers)) == Self.files(for: one), "run \(run)")
        }
    }
}
