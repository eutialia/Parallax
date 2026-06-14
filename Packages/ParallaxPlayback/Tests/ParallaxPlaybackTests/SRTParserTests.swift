import Testing
import Foundation
import CoreMedia
@testable import ParallaxPlayback

@Suite("SRTParser")
struct SRTParserTests {

    private func seconds(_ t: CMTime) -> Double { CMTimeGetSeconds(t) }

    @Test("parses basic SRT: index line, comma-millis timecodes, multi-line text")
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
        #expect(seconds(cues[0].start) == 1.0)
        #expect(seconds(cues[0].end) == 4.0)
        #expect(cues[0].text == "Line one\nLine two")
        #expect(seconds(cues[1].start) == 5.5)
        #expect(seconds(cues[1].end) == 6.0)
        #expect(cues[1].text == "Next")
    }

    @Test("HH:MM:SS,mmm with hours > 0")
    func withHours() {
        let srt = """
        1
        01:02:03,500 --> 01:02:05,000
        Hi

        """
        let cues = SRTParser.parse(srt)
        #expect(cues.count == 1)
        #expect(seconds(cues[0].start) == 3723.5)
        #expect(seconds(cues[0].end) == 3725.0)
    }

    @Test("tolerates CRLF line endings")
    func crlf() {
        let srt = "1\r\n00:00:01,000 --> 00:00:02,000\r\nHello\r\n\r\n"
        let cues = SRTParser.parse(srt)
        #expect(cues.count == 1)
        #expect(cues[0].text == "Hello")
    }

    @Test("tolerates UTF-8 BOM")
    func bom() {
        let bomPrefix = "\u{FEFF}"
        let srt = bomPrefix + "1\n00:00:01,000 --> 00:00:02,000\nHi\n\n"
        let cues = SRTParser.parse(srt)
        #expect(cues.count == 1)
        #expect(cues[0].text == "Hi")
    }

    @Test("re-sorts out-of-order cues by start time")
    func sortsByStart() {
        let srt = """
        1
        00:00:10,000 --> 00:00:12,000
        Later

        2
        00:00:01,000 --> 00:00:02,000
        Earlier

        """
        let cues = SRTParser.parse(srt)
        #expect(cues.map(\.text) == ["Earlier", "Later"])
    }

    @Test("empty and garbage input yield no cues")
    func emptyAndGarbage() {
        #expect(SRTParser.parse("").isEmpty)
        #expect(SRTParser.parse("not a subtitle file at all").isEmpty)
        #expect(SRTParser.parse("1\n\n2\n\n").isEmpty)
    }

    @Test("parses via Data convenience")
    func parsesData() {
        let data = Data("1\n00:00:01,000 --> 00:00:02,000\nHi\n\n".utf8)
        #expect(SRTParser.parse(data: data).first?.text == "Hi")
    }

    @Test("accumulates multi-line text until blank line; trailing whitespace trimmed")
    func multilineAndTrim() {
        let srt = """
        1
        00:00:01,000 --> 00:00:04,000
        First line
        Second line
        Third line

        """
        let cues = SRTParser.parse(srt)
        #expect(cues.first?.text == "First line\nSecond line\nThird line")
    }

    @Test("period as decimal separator (non-standard but tolerated)")
    func periodDecimalSeparator() {
        let srt = """
        1
        00:00:01.500 --> 00:00:02.000
        Dot

        """
        let cues = SRTParser.parse(srt)
        #expect(seconds(cues.first?.start ?? .invalid) == 1.5)
    }

    @Test("cue index line is not treated as text")
    func cueIndexNotInText() {
        let srt = """
        42
        00:00:01,000 --> 00:00:02,000
        Only text

        """
        let cues = SRTParser.parse(srt)
        #expect(cues.first?.text == "Only text")
    }

    @Test("produces SubtitleCue values (not a distinct type)")
    func producesSubtitleCueType() {
        let srt = "1\n00:00:01,000 --> 00:00:02,000\nHi\n\n"
        let cues: [SubtitleCue] = SRTParser.parse(srt)
        #expect(cues.count == 1)
    }
}
