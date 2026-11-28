import Foundation
import ParallaxCoreTestSupport
import Testing
@testable import ParallaxSubtitles

/// SubRip files as muxers really write them: any line ending, a byte order mark or none, index
/// lines present, missing or out of step, either decimal mark, and blank separators left out.
@Suite("SRT conversion")
struct SRTConversionProperties {

    private static let cases = 500

    private static func file(of cues: [GeneratedCue], _ random: inout SeededGenerator) -> String {
        let ending = GeneratedFile.lineEndings.randomElement(using: &random)!
        var lines: [String] = []
        for (number, cue) in cues.enumerated() {
            switch Int.random(in: 0..<4, using: &random) {
            case 0: break
            case 1: lines.append(String(Int.random(in: 10...99_999, using: &random)))
            default: lines.append(String(number + 1))
            }
            lines.append(
                GeneratedCue.timestamp(cue.start, mark: GeneratedFile.mark(&random)) + " --> "
                    + GeneratedCue.timestamp(cue.end, mark: GeneratedFile.mark(&random)))
            lines += cue.lines
            let isLast = number == cues.count - 1
            // Without a blank line a trailing number is the next cue's index, so a cue that
            // ends in one always gets its separator.
            if isLast ? Bool.random(using: &random) : cue.endsInANumber || Int.random(in: 0..<3, using: &random) > 0 {
                lines.append("")
            }
        }
        return GeneratedFile.byteOrderMark(&random) + lines.joined(separator: ending)
            + (Bool.random(using: &random) ? ending : "")
    }

    @Test("every cue comes out once, in file order, with its times and its lines, however the file is written")
    func everyCueSurvives() {
        var random = SeededGenerator(seed: 0x73_7274)
        for run in 0..<Self.cases {
            let cues = GeneratedCue.cues(&random)
            let file = Self.file(of: cues, &random)

            #expect(SRTToASSConverter.events(from: file) == cues.map(\.event), "run \(run): \(file.debugDescription)")
        }
    }

    @Test("the script lists every cue once, earliest first")
    func scriptListsEveryCueInTimeOrder() throws {
        var random = SeededGenerator(seed: 0x736F_7274)
        for run in 0..<Self.cases {
            let events = GeneratedCue.cues(&random).map(\.event)

            let written = cues(ASSScriptBuilder.script(events: events, fontFamily: SubtitleFontBundle.sansFamily))

            let starts = try written.map { try #require(CueMarkup.seconds(fromTimestamp: $0.start)) }
            #expect(zip(starts, starts.dropFirst()).allSatisfy { $0 <= $1 }, "run \(run)")
            let centiseconds = { (seconds: Double) in Int((seconds * 100).rounded()) }
            let key = { (start: Double, end: Double, text: String) in "\(centiseconds(start)) \(centiseconds(end)) \(text)" }
            let expected = events.map { key($0.start, $0.end, $0.text) }.sorted()
            let got = try written.map { key(try #require(CueMarkup.seconds(fromTimestamp: $0.start)), try #require(CueMarkup.seconds(fromTimestamp: $0.end)), $0.text) }.sorted()
            #expect(got == expected, "run \(run)")
        }
    }
}
