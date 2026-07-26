import Testing
import Foundation
import CoreMedia
@testable import ParallaxPlayback

/// WebVTT-specific parsing. The cross-parser behaviours (sorting, garbage tolerance,
/// the `Data` overload) live in `SubtitleParserContractTests`.
@Suite("WebVTTParser")
struct WebVTTParserTests {

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
        #expect(cueSeconds(cues[0].start) == 1.0)
        #expect(cueSeconds(cues[0].end) == 4.0)
        #expect(cues[0].text == "First line")
        #expect(cueSeconds(cues[1].start) == 65.5)
        #expect(cueSeconds(cues[1].end) == 68.0)
        #expect(cues[1].text == "Second line")
    }

    @Test("accepts MM:SS.mmm short timestamps (05:02.250 → 302.25s)")
    func shortTimestamps() {
        let cues = WebVTTParser.parse("WEBVTT\n\n05:02.250 --> 05:04.000\nHi")
        #expect(cues.count == 1)
        #expect(cueSeconds(cues[0].start) == 302.25)
        #expect(cueSeconds(cues[0].end) == 304.0)
    }

    /// One cue body per row; only the payload varies. The literals ARE the spec — this
    /// is a parser and its input format is the contract.
    @Test("cue payload handling", arguments: [
        ("multi-line text joins with newlines", "Line one\nLine two", "Line one\nLine two"),
        ("inline v/i/c/timestamp tags are stripped",
         "<v Bob><i>Hello</i> <c.yellow>there</c><00:00:01.500> world", "Hello there world"),
        ("core entities decode, literal punctuation survives",
         "Tom &amp; Jerry &lt;3 &gt;_&gt;", "Tom & Jerry <3 >_>"),
    ] as [(String, String, String)])
    func cuePayload(label: String, body: String, expected: String) {
        let cues = WebVTTParser.parse("WEBVTT\n\n00:00:01.000 --> 00:00:02.000\n\(body)")
        #expect(cues.count == 1, "\(label): expected exactly one cue")
        #expect(cues.first?.text == expected, "\(label)")
    }

    @Test("non-payload lines never leak into the cue", arguments: [
        ("optional cue identifier", "WEBVTT\n\nintro-cue\n00:00:01.000 --> 00:00:02.000\nBody", "Body", 1.0),
        ("comma decimal separator", "WEBVTT\n\n00:00:01,500 --> 00:00:02,000\nComma", "Comma", 1.5),
        ("cue settings after the end timestamp",
         "WEBVTT\n\n00:00:01.000 --> 00:00:04.000 align:start position:50% line:90%\nPositioned",
         "Positioned", 1.0),
    ] as [(String, String, String, Double)])
    func nonPayloadLinesIgnored(label: String, source: String, text: String, start: Double) {
        let cues = WebVTTParser.parse(source)
        #expect(cues.count == 1, "\(label): expected exactly one cue")
        #expect(cues.first?.text == text, "\(label)")
        #expect(cues.first.map { cueSeconds($0.start) } == start, "\(label)")
    }

    @Test("skips WEBVTT header, NOTE, STYLE and REGION blocks")
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

    /// Jellyfin ships an `X-TIMESTAMP-MAP` whose MPEGTS offset must NOT be applied —
    /// its cue times are already absolute (jellyfin#16647).
    @Test("ignores X-TIMESTAMP-MAP so cue times stay absolute")
    func ignoresTimestampMap() {
        let vtt = """
        WEBVTT
        X-TIMESTAMP-MAP=MPEGTS:900000,LOCAL:00:00:00.000

        00:00:30.000 --> 00:00:32.000
        Absolute
        """
        let cues = WebVTTParser.parse(vtt)
        #expect(cues.count == 1)
        // 30s stays 30s — the 900000/90000 = 10s offset is NOT applied.
        #expect(cueSeconds(cues[0].start) == 30.0)
    }

    @Test("cue settings are dropped from the timing as well as the text")
    func cueSettingsNotInTiming() {
        let vtt = "WEBVTT\n\n00:00:01.000 --> 00:00:04.000 align:start position:50%\nPositioned"
        #expect(WebVTTParser.parse(vtt).first.map { cueSeconds($0.end) } == 4.0)
    }
}
