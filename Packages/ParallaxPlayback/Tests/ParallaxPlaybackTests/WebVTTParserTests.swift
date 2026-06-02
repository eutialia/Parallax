import Testing
import Foundation
import CoreMedia
@testable import ParallaxPlayback

@Suite("WebVTTParser")
struct WebVTTParserTests {

    private func seconds(_ t: CMTime) -> Double { CMTimeGetSeconds(t) }

    @Test("parses multiple cues in order with correct start/end")
    func multipleCues() {
        let vtt = """
        WEBVTT

        1
        00:00:01.000 --> 00:00:04.000
        First line

        2
        00:01:05.500 --> 00:01:08.000
        Second line
        """
        let cues = WebVTTParser.parse(vtt)
        #expect(cues.count == 2)
        #expect(seconds(cues[0].start) == 1.0)
        #expect(seconds(cues[0].end) == 4.0)
        #expect(cues[0].text == "First line")
        #expect(seconds(cues[1].start) == 65.5)
        #expect(seconds(cues[1].end) == 68.0)
        #expect(cues[1].text == "Second line")
    }

    @Test("accepts MM:SS.mmm short timestamps")
    func shortTimestamps() {
        let vtt = """
        WEBVTT

        05:02.250 --> 05:04.000
        Hi
        """
        let cues = WebVTTParser.parse(vtt)
        #expect(cues.count == 1)
        #expect(seconds(cues[0].start) == 302.25)
        #expect(seconds(cues[0].end) == 304.0)
    }

    @Test("joins multi-line cue text with newlines")
    func multilineText() {
        let vtt = """
        WEBVTT

        00:00:01.000 --> 00:00:02.000
        Line one
        Line two
        """
        let cues = WebVTTParser.parse(vtt)
        #expect(cues.first?.text == "Line one\nLine two")
    }

    @Test("strips inline tags (i/b/c/v/timestamp)")
    func stripsTags() {
        let vtt = """
        WEBVTT

        00:00:01.000 --> 00:00:02.000
        <v Bob><i>Hello</i> <c.yellow>there</c><00:00:01.500> world
        """
        let cues = WebVTTParser.parse(vtt)
        #expect(cues.first?.text == "Hello there world")
    }

    @Test("decodes core entities and preserves literal punctuation")
    func decodesEntities() {
        let vtt = """
        WEBVTT

        00:00:01.000 --> 00:00:02.000
        Tom &amp; Jerry &lt;3 &gt;_&gt;
        """
        let cues = WebVTTParser.parse(vtt)
        #expect(cues.first?.text == "Tom & Jerry <3 >_>")
    }

    @Test("ignores WEBVTT header, NOTE, STYLE and REGION blocks")
    func ignoresNonCueBlocks() {
        let vtt = """
        WEBVTT - Some Title

        NOTE
        This is a comment that contains nothing useful.

        STYLE
        ::cue { color: yellow }

        REGION
        id:r1

        00:00:01.000 --> 00:00:02.000
        Only cue
        """
        let cues = WebVTTParser.parse(vtt)
        #expect(cues.count == 1)
        #expect(cues.first?.text == "Only cue")
    }

    @Test("ignores X-TIMESTAMP-MAP so timestamps stay absolute (guards jellyfin#16647)")
    func ignoresTimestampMap() {
        let vtt = """
        WEBVTT
        X-TIMESTAMP-MAP=MPEGTS:900000,LOCAL:00:00:00.000

        00:00:30.000 --> 00:00:32.000
        Absolute
        """
        let cues = WebVTTParser.parse(vtt)
        #expect(cues.count == 1)
        // 30s stays 30s — the MPEGTS offset (900000/90000 = 10s) is NOT applied.
        #expect(seconds(cues[0].start) == 30.0)
    }

    @Test("drops cue-setting tokens after the end timestamp")
    func cueSettingsNotInTextOrTiming() {
        let vtt = """
        WEBVTT

        00:00:01.000 --> 00:00:04.000 align:start position:50% line:90%
        Positioned
        """
        let cues = WebVTTParser.parse(vtt)
        #expect(cues.count == 1)
        #expect(seconds(cues[0].end) == 4.0)
        #expect(cues[0].text == "Positioned")
    }

    @Test("ignores an optional cue identifier line before the timing line")
    func cueIdentifierIgnored() {
        let vtt = """
        WEBVTT

        intro-cue
        00:00:01.000 --> 00:00:02.000
        Body
        """
        let cues = WebVTTParser.parse(vtt)
        #expect(cues.count == 1)
        #expect(cues.first?.text == "Body")
    }

    @Test("tolerates comma as the decimal separator")
    func commaDecimal() {
        let vtt = """
        WEBVTT

        00:00:01,500 --> 00:00:02,000
        Comma
        """
        let cues = WebVTTParser.parse(vtt)
        #expect(seconds(cues.first?.start ?? .invalid) == 1.5)
    }

    @Test("empty and garbage input yield no cues")
    func emptyAndGarbage() {
        #expect(WebVTTParser.parse("").isEmpty)
        #expect(WebVTTParser.parse("not a subtitle file at all").isEmpty)
        #expect(WebVTTParser.parse("WEBVTT\n\n").isEmpty)
    }

    @Test("re-sorts out-of-order cues by start time")
    func sortsByStart() {
        let vtt = """
        WEBVTT

        00:00:10.000 --> 00:00:12.000
        Later

        00:00:01.000 --> 00:00:02.000
        Earlier
        """
        let cues = WebVTTParser.parse(vtt)
        #expect(cues.map(\.text) == ["Earlier", "Later"])
    }

    @Test("parses via Data convenience")
    func parsesData() {
        let data = Data("WEBVTT\n\n00:00:01.000 --> 00:00:02.000\nHi".utf8)
        #expect(WebVTTParser.parse(data: data).first?.text == "Hi")
    }
}
