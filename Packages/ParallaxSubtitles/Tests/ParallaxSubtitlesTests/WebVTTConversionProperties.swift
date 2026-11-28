import Foundation
import ParallaxCoreTestSupport
import Testing
@testable import ParallaxSubtitles

/// WebVTT files with everything a cue can sit among: a titled signature, an X-TIMESTAMP-MAP
/// header, cue identifiers, NOTE, STYLE and REGION blocks, cue settings, and cues timed past
/// the hundred hours a timestamp may name.
@Suite("WebVTT conversion")
struct WebVTTConversionProperties {

    private static let cases = 500

    private struct Block {
        let lines: [String]
        /// Nil for a block that is no cue, or a cue the converter must leave out.
        let cue: GeneratedCue?
        let settings: String
    }

    private static let settingTokens = [
        "align:start", "align:end", "align:left", "align:right", "align:center", "align:",
        "position:25%", "position:80%", "position:nan%", "line:5%", "line:50%", "line:90%",
        "line:90%,end", "line:0", "line:-1", "line:,end", "line:1e999%", "vertical:rl", "size:50%",
    ]

    private static let commentLines = [
        "::cue { color: yellow }", "id:r1", "00:00:01.000 --> 00:00:02.000", "a comment", "not a cue",
    ]

    private static func cueBlock(_ random: inout SeededGenerator) -> Block {
        let cue = GeneratedCue.cue(&random)
        let pastTheLimit = Int.random(in: 0..<8, using: &random)
        let start = pastTheLimit == 0 ? cue.start + 360_000_000 : cue.start
        let end = pastTheLimit <= 1 ? cue.end + 360_000_000 : cue.end
        let short = Bool.random(using: &random)
        let settings = (0..<[0, 0, 1, 2, 3].randomElement(using: &random)!)
            .map { _ in settingTokens.randomElement(using: &random)! }.joined(separator: " ")
        let timing = GeneratedCue.timestamp(start, mark: GeneratedFile.mark(&random), short: short) + " --> "
            + GeneratedCue.timestamp(end, mark: GeneratedFile.mark(&random), short: short)
            + (settings.isEmpty ? "" : " " + settings)
        let identifier = Int.random(in: 0..<3, using: &random) == 0 ? ["cue-\(Int.random(in: 0...999, using: &random))"] : []
        return Block(lines: identifier + [timing] + cue.lines, cue: pastTheLimit <= 1 ? nil : cue, settings: settings)
    }

    private static func commentBlock(_ random: inout SeededGenerator) -> Block {
        let first = ["NOTE", "NOTE a comment", "STYLE", "REGION"].randomElement(using: &random)!
        let body = (0..<Int.random(in: 0...2, using: &random)).map { _ in commentLines.randomElement(using: &random)! }
        return Block(lines: [first] + body, cue: nil, settings: "")
    }

    private static func file(_ random: inout SeededGenerator) -> (text: String, blocks: [Block]) {
        let ending = GeneratedFile.lineEndings.randomElement(using: &random)!
        let blocks = (0..<Int.random(in: 1...20, using: &random)).map { _ in
            Int.random(in: 0..<4, using: &random) == 0 ? commentBlock(&random) : cueBlock(&random)
        }
        let header = ["WEBVTT" + (Bool.random(using: &random) ? " - A title" : "")]
            + (Bool.random(using: &random) ? ["X-TIMESTAMP-MAP=MPEGTS:900000,LOCAL:00:00:00.000"] : [])
        let blank = { (random: inout SeededGenerator) in
            String(repeating: ending, count: Int.random(in: 0..<5, using: &random) == 0 ? 3 : 2)
        }
        // Only a cue may follow the signature without a blank line: a comment there is not a
        // block of its own.
        let startsWithACue = blocks[0].lines[0].contains("-->") || blocks[0].lines.count > 1 && blocks[0].lines[1].contains("-->") && blocks[0].lines[0].hasPrefix("cue-")
        var text = GeneratedFile.byteOrderMark(&random) + header.joined(separator: ending)
            + (startsWithACue && Bool.random(using: &random) ? ending : blank(&random))
        for (number, block) in blocks.enumerated() {
            text += block.lines.joined(separator: ending)
            text += number == blocks.count - 1 ? (Bool.random(using: &random) ? ending : "") : blank(&random)
        }
        return (text, blocks)
    }

    private static func withoutPlacement(_ text: String) -> String {
        guard text.hasPrefix("{\\an"), let close = text.firstIndex(of: "}") else { return text }
        return String(text[text.index(after: close)...])
    }

    @Test("every cue inside a hundred hours comes out once, in file order, with its times and its lines, and nothing else does")
    func onlyCuesComeOut() {
        var random = SeededGenerator(seed: 0x76_7474)
        for run in 0..<Self.cases {
            let file = Self.file(&random)
            let kept = file.blocks.filter { $0.cue != nil }

            let events = WebVTTToASSConverter.events(from: file.text)

            let context = "run \(run): \(file.text.debugDescription)"
            #expect(events.map(\.start) == kept.map { $0.cue!.event.start }, "\(context)")
            #expect(events.map(\.end) == kept.map { $0.cue!.event.end }, "\(context)")
            #expect(events.map { Self.withoutPlacement($0.text) } == kept.map { $0.cue!.event.text }, "\(context)")
            for (event, block) in zip(events, kept) where block.settings.isEmpty {
                #expect(event.text == block.cue!.event.text, "\(context)")
            }
        }
    }
}
