import Foundation
import ParallaxCoreTestSupport
import Testing
@testable import ParallaxSubtitles

@Suite("UTF-8 reading")
struct ASSTextEncodingProperties {

    private static let cases = 500
    private static let alphabet = Array("abc [Events]\n,:é—字幕한🙂")

    private static func scalars(_ random: inout SeededGenerator, count: ClosedRange<Int>) -> [String] {
        (0..<Int.random(in: count, using: &random)).map { _ in String(alphabet.randomElement(using: &random)!) }
    }

    @Test("UTF-8 text reads back as written")
    func textReadsBack() {
        var random = SeededGenerator(seed: 0x75_7438)
        for run in 0..<Self.cases {
            let text = Self.scalars(&random, count: 1...200).joined()

            #expect(ASSTextEncoding.utf8(Data(text.utf8)) == text, "run \(run)")
        }
    }

    @Test("one damaged byte costs one replacement character and nothing around it")
    func oneDamagedByteIsForgiven() {
        var random = SeededGenerator(seed: 0x6F_6E65)
        for run in 0..<Self.cases {
            let pieces = Self.scalars(&random, count: 1...200)
            let cut = Int.random(in: 0...pieces.count, using: &random)
            let before = pieces[..<cut].joined(), after = pieces[cut...].joined()

            let read = ASSTextEncoding.utf8(Data(before.utf8) + [0xC3] + Data(after.utf8))

            #expect(read == before + "\u{FFFD}" + after, "run \(run)")
        }
    }

    @Test("text damaged in more than one place in a thousand is not read as UTF-8")
    func heavyDamageIsRefused() {
        var random = SeededGenerator(seed: 0x6D_616E79)
        for run in 0..<Self.cases {
            let pieces = Self.scalars(&random, count: 0...200)
            let damage = Int.random(in: 2...8, using: &random)
            let cuts = Set((0..<damage).map { _ in Int.random(in: 0...pieces.count, using: &random) })
            guard cuts.count >= 2 else { continue }
            let bytes = (0...pieces.count).flatMap { index in
                (cuts.contains(index) ? [UInt8(0xFF)] : []) + (index < pieces.count ? Array(pieces[index].utf8) : [])
            }

            #expect(ASSTextEncoding.utf8(Data(bytes)) == nil, "run \(run)")
        }
    }
}
