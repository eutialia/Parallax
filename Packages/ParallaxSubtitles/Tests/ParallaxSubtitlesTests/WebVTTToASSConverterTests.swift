import Foundation
import Testing

@testable import ParallaxSubtitles

@Suite("WebVTT to ASS")
struct WebVTTToASSConverterTests {

    private func script(_ source: String) -> String {
        WebVTTToASSConverter.script(from: source, fontFamily: SubtitleFontBundle.sansFamily)
    }

    private func cue(body: String, settings: String = "") -> (start: String, end: String, text: String)? {
        let timing = "00:00:01.000 --> 00:00:04.000\(settings.isEmpty ? "" : " " + settings)"
        return cues(script("WEBVTT\n\n\(timing)\n\(body)")).first
    }

    @Test("period-millisecond and short timestamps convert to centiseconds", arguments: [
        ("full timestamps", "00:00:01.000 --> 00:00:04.250", "0:00:01.00", "0:00:04.25"),
        ("MM:SS.mmm short form", "05:02.250 --> 05:04.000", "0:05:02.25", "0:05:04.00"),
        ("comma decimal mark", "00:00:01,500 --> 00:00:02.000", "0:00:01.50", "0:00:02.00"),
        ("hours", "01:02:03.500 --> 01:02:05.000", "1:02:03.50", "1:02:05.00"),
    ] as [(String, String, String, String)])
    func timingConversion(label: String, timing: String, start: String, end: String) {
        let converted = cues(script("WEBVTT\n\n\(timing)\nHi"))
        #expect(converted.count == 1, "\(label)")
        #expect(converted.first?.start == start, "\(label)")
        #expect(converted.first?.end == end, "\(label)")
    }

    @Test("cue payload handling", arguments: [
        ("multi-line joins with a hard break", "Line one\nLine two", "Line one\\NLine two"),
        ("voice, class and timestamp tags are stripped",
         "<v Bob><i>Hello</i> <c.yellow>there</c><00:00:01.500> world",
         "{\\i1}Hello{\\i0} there world"),
        ("core entities decode", "Tom &amp; Jerry &lt;3 &gt;_&gt;", "Tom & Jerry <3 >_>"),
        ("numeric entities decode", "caf&#233; &#x2014; bar", "caf\u{00E9} \u{2014} bar"),
        ("unknown entities stay literal", "50&percnt; sure", "50&percnt; sure"),
        ("ruby markup collapses", "<ruby>漢<rt>かん</rt></ruby>", "漢かん"),
        ("decoded braces still get escaped", "&#123;x&#125;", "\\{x\\}"),
    ] as [(String, String, String)])
    func cuePayload(label: String, body: String, expected: String) {
        #expect(cue(body: body)?.text == expected, "\(label)")
    }

    @Test("non-payload lines never leak into the cue", arguments: [
        ("optional cue identifier", "WEBVTT\n\nintro-cue\n00:00:01.000 --> 00:00:02.000\nBody", "Body"),
        ("no blank line after the signature", "WEBVTT\n00:00:01.000 --> 00:00:02.000\nBody", "Body"),
        ("settings on the timing line",
         "WEBVTT\n\n00:00:01.000 --> 00:00:02.000 align:start position:50% line:90%\nBody", "Body"),
    ] as [(String, String, String)])
    func nonPayloadLines(label: String, source: String, expected: String) {
        let converted = cues(script(source))
        #expect(converted.count == 1, "\(label)")
        #expect(converted.first?.text.hasSuffix(expected) == true, "\(label)")
    }

    @Test("NOTE, STYLE and REGION blocks are skipped")
    func nonCueBlocks() {
        let converted = cues(
            script(
                """
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
            )
        )
        #expect(converted.map(\.text) == ["Only cue"])
    }

    /// Jellyfin ships an X-TIMESTAMP-MAP whose MPEGTS offset must NOT be applied:
    /// its cue times are already absolute (jellyfin#16647).
    @Test("X-TIMESTAMP-MAP leaves cue times alone")
    func timestampMapIgnored() {
        let converted = cues(
            script(
                """
                WEBVTT
                X-TIMESTAMP-MAP=MPEGTS:900000,LOCAL:00:00:00.000

                00:00:30.000 --> 00:00:32.000
                Absolute
                """
            )
        )
        // 30s stays 30s; the 900000/90000 = 10s offset is not applied.
        #expect(converted.map(\.start) == ["0:00:30.00"])
    }

    // MARK: - Cue settings

    /// The part ffmpeg's converter throws away. Each row is a real settings
    /// string and the ASS override block it has to become.
    @Test("cue settings map to ASS placement", arguments: [
        ("nothing set leaves the default flow", "", ""),
        ("align only keeps collision handling", "align:start", "{\\an1}"),
        ("align end", "align:end", "{\\an3}"),
        ("left and right are align synonyms", "align:right", "{\\an3}"),
        ("line percentage picks the top band", "line:5%", "{\\an8\\pos(640,36)}"),
        ("line percentage picks the middle band", "line:50%", "{\\an5\\pos(640,360)}"),
        ("line percentage picks the bottom band", "line:90%", "{\\an2\\pos(640,648)}"),
        ("line number 0 is the top line", "line:0", "{\\an8}"),
        ("negative line numbers count from the bottom", "line:-1", "{\\an2}"),
        ("position alone anchors on the default baseline", "position:25%", "{\\an2\\pos(320,684)}"),
        ("line and position together", "line:10% position:80%", "{\\an8\\pos(1024,72)}"),
        // No `position:`, so x falls back to the margin the alignment implies.
        ("align combines with the band", "line:5% align:start", "{\\an7\\pos(40,36)}"),
        ("trailing line alignment hint is ignored", "line:90%,end", "{\\an2\\pos(640,648)}"),
        ("unmapped settings are dropped", "vertical:rl size:50%", ""),
        // Malformed settings must fail open (dropped, no crash) rather than trap.
        ("empty align value does not crash and picks the default corner", "align:", "{\\an2}"),
        ("empty line value before a trailing hint parses as empty, not the hint",
         "line:,end", ""),
        ("NaN position is dropped, not applied", "position:nan%", ""),
        ("an out-of-range line percentage is dropped, not applied", "line:1e999%", ""),
    ] as [(String, String, String)])
    func cueSettings(label: String, settings: String, expected: String) {
        #expect(cue(body: "Hi", settings: settings)?.text == expected + "Hi", "\(label)")
    }

    @Test("out-of-order cues are re-sorted by start time")
    func sorting() {
        let converted = cues(
            script(
                """
                WEBVTT

                00:00:10.000 --> 00:00:12.000
                Later

                00:00:01.000 --> 00:00:02.000
                Earlier
                """
            )
        )
        #expect(converted.map(\.text) == ["Earlier", "Later"])
    }

    /// A cue timed past 100 hours would overflow the Double->Int conversion in
    /// ASSScriptBuilder.timecode; CueMarkup rejects it at parse time instead, and
    /// the malformed cue is simply dropped.
    @Test("a cue timed past 100 hours is dropped, not converted")
    func extremeTimestampDropped() {
        let converted = cues(
            script(
                """
                WEBVTT

                00:00:01.000 --> 00:00:02.000
                Kept

                100:00:00.000 --> 100:00:01.000
                Dropped
                """
            )
        )
        #expect(converted.map(\.text) == ["Kept"])
    }

    @Test("structurally broken input yields no cues", arguments: [
        ("empty", ""),
        ("signature only", "WEBVTT\n\n"),
        ("prose", "not a subtitle file at all"),
        ("timing with no text", "WEBVTT\n\n00:00:01.000 --> 00:00:02.000\n\n"),
    ] as [(String, String)])
    func garbage(label: String, source: String) {
        #expect(cues(script(source)).isEmpty, "\(label)")
    }
}
