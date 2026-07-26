import Testing
import Foundation
import CoreMedia
@testable import ParallaxPlayback

/// SRT-specific parsing. The cross-parser behaviours (sorting, garbage tolerance, the
/// `Data` overload) live in `SubtitleParserContractTests`.
@Suite("SRTParser")
struct SRTParserTests {

    @Test("parses index line, comma-millis timecodes and multi-line text")
    func parsesBasicSRT() {
        let srt = """
        1
        00:00:01,000 --> 00:00:04,000
        Line one
        Line two

        2
        00:00:05,500 --> 00:00:06,000
        Next

        """
        let cues = SRTParser.parse(srt)
        #expect(cues.count == 2)
        #expect(cueSeconds(cues[0].start) == 1.0)
        #expect(cueSeconds(cues[0].end) == 4.0)
        #expect(cues[0].text == "Line one\nLine two")
        #expect(cueSeconds(cues[1].start) == 5.5)
        #expect(cueSeconds(cues[1].end) == 6.0)
        #expect(cues[1].text == "Next")
    }

    @Test("converts the hours field (01:02:03,500 → 3723.5s)")
    func withHours() {
        let cues = SRTParser.parse("1\n01:02:03,500 --> 01:02:05,000\nHi\n\n")
        #expect(cues.count == 1)
        #expect(cueSeconds(cues[0].start) == 3723.5)
        #expect(cueSeconds(cues[0].end) == 3725.0)
    }

    @Test("accumulates every text line until the blank separator")
    func multilineAndTrim() {
        let srt = """
        1
        00:00:01,000 --> 00:00:04,000
        First line
        Second line
        Third line

        """
        #expect(SRTParser.parse(srt).first?.text == "First line\nSecond line\nThird line")
    }

    /// Every row is the same one-cue file written the way some real muxer writes it.
    /// The literals here ARE the spec — this is a parser, its input format is the
    /// contract.
    @Test("tolerated encoding/format variations all yield the same cue", arguments: [
        ("CRLF line endings", "1\r\n00:00:01,000 --> 00:00:02,000\r\nHello\r\n\r\n", "Hello", 1.0),
        ("UTF-8 BOM", "\u{FEFF}1\n00:00:01,000 --> 00:00:02,000\nHi\n\n", "Hi", 1.0),
        ("period decimal separator", "1\n00:00:01.500 --> 00:00:02.000\nDot\n\n", "Dot", 1.5),
        ("multi-digit cue index", "42\n00:00:01,000 --> 00:00:02,000\nOnly text\n\n", "Only text", 1.0),
        ("no cue index line", "00:00:01,000 --> 00:00:02,000\nNo index\n\n", "No index", 1.0),
        ("bare CR line endings", "1\r00:00:01,000 --> 00:00:02,000\rMac\r\r", "Mac", 1.0),
    ] as [(String, String, String, Double)])
    func toleratedVariations(label: String, source: String, text: String, start: Double) {
        let cues = SRTParser.parse(source)
        #expect(cues.count == 1, "\(label): expected exactly one cue, got \(cues.count)")
        #expect(cues.first?.text == text, "\(label)")
        #expect(cues.first.map { cueSeconds($0.start) } == start, "\(label)")
    }
}
