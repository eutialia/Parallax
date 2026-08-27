import Foundation
import Testing

@testable import ParallaxSubtitles

@Suite("SRT to ASS")
struct SRTToASSConverterTests {

    private func script(_ source: String) -> String {
        SRTToASSConverter.script(from: source, fontFamily: SubtitleFontBundle.sansFamily)
    }

    @Test("comma-millisecond timecodes become centisecond ASS timecodes")
    func timingConversion() {
        let converted = cues(
            script(
                """
                1
                00:00:01,000 --> 00:00:04,250
                Line one
                Line two

                2
                01:02:03,500 --> 01:02:05,000
                Later

                """
            )
        )
        #expect(converted.count == 2)
        #expect(converted[0].start == "0:00:01.00")
        #expect(converted[0].end == "0:00:04.25")
        // Multi-line cues become one event with a hard ASS break.
        #expect(converted[0].text == "Line one\\NLine two")
        #expect(converted[1].start == "1:02:03.50")
        #expect(converted[1].end == "1:02:05.00")
    }

    /// Every row is the same one-cue file as some real muxer writes it. The
    /// literals ARE the spec: this is a parser and its input format is the contract.
    @Test("tolerated encoding and format variations all yield the same cue", arguments: [
        ("CRLF endings", "1\r\n00:00:01,000 --> 00:00:02,000\r\nHello\r\n\r\n", "Hello", "0:00:01.00"),
        ("UTF-8 BOM", "\u{FEFF}1\n00:00:01,000 --> 00:00:02,000\nHello\n\n", "Hello", "0:00:01.00"),
        ("period decimal mark", "1\n00:00:01.500 --> 00:00:02,000\nHello\n\n", "Hello", "0:00:01.50"),
        ("multi-digit index", "42\n00:00:01,000 --> 00:00:02,000\nHello\n\n", "Hello", "0:00:01.00"),
        ("no index line", "00:00:01,000 --> 00:00:02,000\nHello\n\n", "Hello", "0:00:01.00"),
        ("bare CR endings", "1\r00:00:01,000 --> 00:00:02,000\rHello\r\r", "Hello", "0:00:01.00"),
        ("no trailing blank line", "1\n00:00:01,000 --> 00:00:02,000\nHello", "Hello", "0:00:01.00"),
    ] as [(String, String, String, String)])
    func toleratedVariations(label: String, source: String, text: String, start: String) {
        let converted = cues(script(source))
        #expect(converted.count == 1, "\(label): expected exactly one cue, got \(converted.count)")
        #expect(converted.first?.text == text, "\(label)")
        #expect(converted.first?.start == start, "\(label)")
    }

    @Test("inline markup maps to ASS override tags", arguments: [
        ("italic", "<i>Hi</i>", "{\\i1}Hi{\\i0}"),
        ("bold", "<b>Hi</b>", "{\\b1}Hi{\\b0}"),
        ("underline", "<u>Hi</u>", "{\\u1}Hi{\\u0}"),
        ("uppercase tags", "<I>Hi</I>", "{\\i1}Hi{\\i0}"),
        ("font tags are dropped, text survives", "<font color=\"#ff0000\">Hi</font>", "Hi"),
        ("unknown tags collapse", "<ruby>Hi</ruby><br/>There", "HiThere"),
        ("unterminated angle bracket stays literal", "2 < 3", "2 < 3"),
    ] as [(String, String, String)])
    func markupMapping(label: String, body: String, expected: String) {
        let converted = cues(script("1\n00:00:01,000 --> 00:00:02,000\n\(body)\n\n"))
        #expect(converted.count == 1, "\(label)")
        #expect(converted.first?.text == expected, "\(label)")
    }

    /// Placing an SRT line at the top of the screen with a literal `{\an8}` is a
    /// widespread convention. The tag has to reach libass intact for that to work.
    @Test("literal alignment overrides pass through", arguments: [
        ("an form", "{\\an8}Top", "{\\an8}Top"),
        ("legacy a form", "{\\a6}Top", "{\\a6}Top"),
        ("mid-line", "Before {\\an8}after", "Before {\\an8}after"),
    ] as [(String, String, String)])
    func alignmentPassthrough(label: String, body: String, expected: String) {
        let converted = cues(script("1\n00:00:01,000 --> 00:00:02,000\n\(body)\n\n"))
        #expect(converted.first?.text == expected, "\(label)")
    }

    /// A stray brace would otherwise open an override block and swallow the rest
    /// of the line; a stray backslash would eat the character after it.
    @Test("braces and backslashes that are not overrides get escaped", arguments: [
        ("stray open brace", "a {b c", "a \\{b c"),
        ("stray close brace", "a} b", "a\\} b"),
        ("non-alignment override text", "{\\fs40}Big", "\\{\\\\fs40\\}Big"),
        ("windows path", "C:\\Users", "C:\\\\Users"),
    ] as [(String, String, String)])
    func escaping(label: String, body: String, expected: String) {
        let converted = cues(script("1\n00:00:01,000 --> 00:00:02,000\n\(body)\n\n"))
        #expect(converted.first?.text == expected, "\(label)")
    }

    /// Files that omit the blank separator leave the next cue's index number
    /// dangling at the end of the previous cue's text. It is an index there, but a
    /// number ending a properly separated cue is real dialogue and has to survive.
    @Test("a bare number is an index only when a timing line follows it", arguments: [
        ("missing blank separator",
         "1\n00:00:01,000 --> 00:00:02,000\nHello\n2\n00:00:03,000 --> 00:00:04,000\nWorld\n",
         ["Hello", "World"]),
        ("missing separator on every cue",
         "1\n00:00:01,000 --> 00:00:02,000\nOne\n2\n00:00:03,000 --> 00:00:04,000\nTwo\n"
             + "3\n00:00:05,000 --> 00:00:06,000\nThree\n",
         ["One", "Two", "Three"]),
        ("trailing number with a blank separator is dialogue",
         "1\n00:00:01,000 --> 00:00:02,000\nHello\n2\n\n", ["Hello\\N2"]),
        ("trailing number at end of file is dialogue",
         "1\n00:00:01,000 --> 00:00:02,000\nHello\n2", ["Hello\\N2"]),
        ("a number mid-body is dialogue",
         "1\n00:00:01,000 --> 00:00:02,000\nHello\n2\nmore\n\n", ["Hello\\N2\\Nmore"]),
        ("countdown text survives when properly separated",
         "1\n00:00:01,000 --> 00:00:02,000\n3\n\n2\n00:00:03,000 --> 00:00:04,000\n2\n\n",
         ["3", "2"]),
    ] as [(String, String, [String])])
    func bareIndexDisambiguation(label: String, source: String, expected: [String]) {
        #expect(cues(script(source)).map(\.text) == expected, "\(label)")
    }

    @Test("out-of-order cues are re-sorted by start time")
    func sorting() {
        let converted = cues(
            script(
                """
                1
                00:00:10,000 --> 00:00:12,000
                Later

                2
                00:00:01,000 --> 00:00:02,000
                Earlier

                """
            )
        )
        #expect(converted.map(\.text) == ["Earlier", "Later"])
    }

    /// A garbled sidecar must degrade to "no subtitles" rather than junk on screen.
    @Test("structurally broken input yields no cues", arguments: [
        ("empty", ""),
        ("prose", "not a subtitle file at all"),
        ("indices only", "1\n\n2\n\n"),
        ("timing with no text", "1\n00:00:01,000 --> 00:00:02,000\n\n"),
        ("unparseable timestamps", "1\nzz:zz --> qq\nHello\n\n"),
    ] as [(String, String)])
    func garbage(label: String, source: String) {
        #expect(cues(script(source)).isEmpty, "\(label)")
    }

    @Test("the synthesized script carries a Default style at the requested font")
    func synthesizedStyle() {
        let generated = SRTToASSConverter.script(
            from: "1\n00:00:01,000 --> 00:00:02,000\nHi\n\n",
            fontFamily: "Avenir Next"
        )
        #expect(generated.contains("PlayResX: 1280"))
        #expect(generated.contains("PlayResY: 720"))
        #expect(generated.contains("Style: Default,Avenir Next,48,"))
        // Bottom-centre alignment, so converted tracks look like normal subtitles.
        #expect(generated.contains(",1,2.4,1.2,2,40,40,36,1"))
    }

    /// A comma in the font name would shift every later field of the style line.
    @Test("commas in the font family cannot break the style line")
    func fontNameWithComma() {
        let generated = SRTToASSConverter.script(
            from: "1\n00:00:01,000 --> 00:00:02,000\nHi\n\n",
            fontFamily: "Bad, Font"
        )
        #expect(generated.contains("Style: Default,Bad Font,48,"))
    }
}
