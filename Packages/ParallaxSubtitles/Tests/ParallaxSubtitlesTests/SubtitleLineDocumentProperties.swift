import Foundation
import ParallaxCoreTestSupport
import Testing
@testable import ParallaxSubtitles

/// Lines as a Matroska file stores them, written out as the file a renderer loads.
@Suite("A subtitle written out from its lines")
struct SubtitleLineDocumentProperties {

    private static let cases = 300

    private struct StoredEvent {
        let readOrder: Int
        /// By field name, the two times left out.
        let fields: [String: String]
        let line: SubtitleLine
    }

    private static let storedFields = ["layer", "style", "name", "marginl", "marginr", "marginv", "effect"]

    /// An event format as a script may declare it: the two times, any of the other standard
    /// fields in any order, an SSA script's `Marked` for the layer, and the text last.
    private static func eventFormat(_ random: inout SeededGenerator) -> [String] {
        let named = storedFields.filter { _ in Int.random(in: 0..<4, using: &random) > 0 }
            .map { $0 == "layer" && Bool.random(using: &random) ? "marked" : $0 }
        return (named + ["start", "end"]).shuffled(using: &random) + ["text"]
    }

    private static func header(declaring format: [String]?, _ random: inout SeededGenerator) -> String {
        let ending = Bool.random(using: &random) ? "\r\n" : "\n"
        var lines = ["[Script Info]", "PlayResX: 1920", "", "[V4+ Styles]", "Format: Name, Fontname", "Style: Default,Arial"]
        if let format {
            lines += ["", Bool.random(using: &random) ? "[Events]" : "[events]", "Format: " + format.joined(separator: ", ")]
        }
        return lines.joined(separator: ending) + (Bool.random(using: &random) ? ending : "")
    }

    /// Events as Matroska stores them: the read order, then the seven fields and the text in
    /// its fixed order, whatever `format` the script declares.
    private static func events(storedIn format: [String], _ random: inout SeededGenerator) -> [StoredEvent] {
        (0..<Int.random(in: 1...12, using: &random)).shuffled(using: &random).map { readOrder in
            var fields = Dictionary(uniqueKeysWithValues: storedFields.map {
                ($0, String(Int.random(in: 0...99, using: &random)))
            })
            fields["text"] = (0..<Int.random(in: 1...3, using: &random)).map { _ in GeneratedCue.line(&random) }
                .joined(separator: Bool.random(using: &random) ? "," : "\\N")
            let stored = (storedFields + ["text"]).compactMap { fields[$0] }
            if format.contains("marked") { fields["marked"] = fields["layer"] }
            fields = fields.filter { format.contains($0.key) }
            return StoredEvent(
                readOrder: readOrder, fields: fields,
                line: SubtitleLine(
                    start: .milliseconds(Int.random(in: 0..<7_200_000, using: &random)),
                    duration: .milliseconds(Int.random(in: 10...9000, using: &random)),
                    content: Data(([String(readOrder)] + stored).joined(separator: ",").utf8)))
        }
    }

    private static func written(_ events: [StoredEvent], after header: String) -> String {
        let document = SubtitleLineDocument.document(of: events.map(\.line), format: .ass(header: Data(header.utf8)))
        return String(decoding: document.data, as: UTF8.self)
    }

    private static func dialogue(in script: String, fields: Int = 10) -> [[String]] {
        script.split(whereSeparator: \.isNewline).filter { $0.hasPrefix("Dialogue: ") }.map {
            $0.dropFirst("Dialogue: ".count).split(separator: ",", maxSplits: fields - 1, omittingEmptySubsequences: false).map(String.init)
        }
    }

    @Test("an ASS script starts with its header as stored, and holds each line once in read order, each stored field under its name in the script's own event format")
    func assEventsKeepTheirFields() throws {
        var random = SeededGenerator(seed: 0x6173_73)
        for run in 0..<Self.cases {
            let format = Self.eventFormat(&random)
            let header = Self.header(declaring: format, &random)
            let events = Self.events(storedIn: format, &random)

            let script = Self.written(events, after: header)

            #expect(script.hasPrefix(header), "run \(run)")
            let lines = Self.dialogue(in: script, fields: format.count)
            let expected = events.sorted { $0.readOrder < $1.readOrder }
            try #require(lines.count == expected.count, "run \(run): \(script)")
            for (line, event) in zip(lines, expected) {
                let named = Dictionary(uniqueKeysWithValues: zip(format, line))
                #expect(named.filter { $0.key != "start" && $0.key != "end" } == event.fields, "run \(run): \(script)")
                #expect(named["start"] == SubtitleLineDocument.timecode(event.line.start), "run \(run)")
                #expect(named["end"] == SubtitleLineDocument.timecode(event.line.start + event.line.duration), "run \(run)")
            }
        }
    }

    @Test("a header with no event format gets the standard one, and its lines are written in it")
    func headerWithoutEventsGetsTheStandardFormat() throws {
        var random = SeededGenerator(seed: 0x6576_74)
        for run in 0..<Self.cases {
            let events = Self.events(storedIn: SubtitleLineDocument.standardEventFields, &random)

            let script = Self.written(events, after: Self.header(declaring: nil, &random))

            let declared = try #require(SubtitleLineDocument.eventFields(in: Data(script.utf8)), "run \(run): \(script)")
            #expect(declared == SubtitleLineDocument.standardEventFields, "run \(run)")
            let texts = Self.dialogue(in: script).map(\.[9])
            #expect(texts == events.sorted { $0.readOrder < $1.readOrder }.compactMap(\.fields["text"]), "run \(run): \(script)")
        }
    }

    @Test("a stored event with fewer fields than Matroska gives one is left out, and the events around it are written")
    func shortEventsAreLeftOut() {
        var random = SeededGenerator(seed: 0x7368_6F72)
        for run in 0..<Self.cases {
            let events = Self.events(storedIn: SubtitleLineDocument.standardEventFields, &random)
            let cut = Int.random(in: 0..<events.count, using: &random)
            let lines = events.enumerated().map { place, event in
                guard place == cut else { return event.line }
                let kept = event.line.content.split(separator: UInt8(ascii: ","), omittingEmptySubsequences: false)
                    .prefix(Int.random(in: 1...8, using: &random))
                return SubtitleLine(
                    start: event.line.start, duration: event.line.duration, content: Data(kept.joined(separator: [UInt8(ascii: ",")])))
            }

            let document = SubtitleLineDocument.document(of: lines, format: .ass(header: Data(Self.header(declaring: nil, &random).utf8)))

            let orders = events.enumerated().filter { $0.offset != cut }.map(\.element.readOrder).sorted()
            let texts = Self.dialogue(in: String(decoding: document.data, as: UTF8.self)).map(\.[9])
            #expect(texts == orders.compactMap { order in events.first { $0.readOrder == order }?.fields["text"] }, "run \(run)")
        }
    }

    @Test("a time is written to the hundredth of a second it is nearest, and reads back as that")
    func timecodeReadsBack() throws {
        var random = SeededGenerator(seed: 0x7463)
        for run in 0..<Self.cases {
            let milliseconds = Int.random(in: 0..<36_000_000, using: &random)

            let written = SubtitleLineDocument.timecode(.milliseconds(milliseconds))

            let read = try #require(CueMarkup.seconds(fromTimestamp: written), "run \(run): \(written)")
            #expect(abs(read * 1000 - Double(milliseconds)) < 5.001, "run \(run): \(written) for \(milliseconds) ms")
        }
    }

    @Test("an SRT file written from lines converts back to every line once, earliest first, with its times and its text, whatever order the lines came in")
    func srtLinesSurvive() {
        var random = SeededGenerator(seed: 0x7372_746C)
        for run in 0..<Self.cases {
            let cues = GeneratedCue.cues(&random).filter { $0.end > $0.start }
            let ending = Bool.random(using: &random) ? "\r\n" : "\n"
            // A blank line inside a line's text is not kept: in a file it would end the cue.
            let lines = cues.map { cue in
                SubtitleLine(
                    start: .milliseconds(cue.start), duration: .milliseconds(cue.end - cue.start),
                    content: Data(cue.lines.flatMap { Bool.random(using: &random) ? [$0] : [$0, " "].shuffled(using: &random) + [""] }
                        .joined(separator: ending).utf8))
            }

            let document = SubtitleLineDocument.document(of: lines.shuffled(using: &random), format: .srt)

            let events = SRTToASSConverter.events(from: String(decoding: document.data, as: UTF8.self))
            let expected = cues.sorted { $0.start < $1.start }.map(\.event)
            #expect(events.map(\.text).sorted() == expected.map(\.text).sorted(), "run \(run)")
            #expect(events.map(\.start) == expected.map(\.start), "run \(run)")
            #expect(Set(events.map { "\($0.start) \($0.end) \($0.text)" }) == Set(expected.map { "\($0.start) \($0.end) \($0.text)" }), "run \(run)")
        }
    }

    @Test("a line that ends before the player's time zero is left out, and one that spans zero starts at zero")
    func linesBeforeZero() {
        var random = SeededGenerator(seed: 0x7A65_726F)
        for run in 0..<Self.cases {
            let start = Int.random(in: -5000 ... -1, using: &random)
            let length = Int.random(in: 1...10_000, using: &random)
            let line = SubtitleLine(start: .milliseconds(start), duration: .milliseconds(length), content: Data("0,0,Default,,0,0,0,,x".utf8))

            let script = Self.written([StoredEvent(readOrder: 0, fields: [:], line: line)], after: Self.header(declaring: nil, &random))
            let srt = String(decoding: SubtitleLineDocument.document(of: [line], format: .srt).data, as: UTF8.self)

            let shown = start + length > 0
            #expect(Self.dialogue(in: script).map(\.[1]) == (shown ? ["0:00:00.00"] : []), "run \(run)")
            #expect(srt.isEmpty == !shown, "run \(run)")
            #expect(!shown || srt.contains("00:00:00,000 --> "), "run \(run)")
        }
    }
}
