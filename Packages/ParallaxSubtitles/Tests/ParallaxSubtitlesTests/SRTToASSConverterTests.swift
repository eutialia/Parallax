import Foundation
import Testing

@testable import ParallaxSubtitles

@Suite("SRT to ASS")
struct SRTToASSConverterTests {

    private func script(_ source: String) -> String {
        ASSScriptBuilder.script(
            events: SRTToASSConverter.events(from: source), fontFamily: SubtitleFontBundle.sansFamily
        )
    }

    @Test("inline markup maps to ASS override tags", arguments: [
        ("italic", "<i>Hi</i>", "{\\i1}Hi{\\i0}"),
        ("bold", "<b>Hi</b>", "{\\b1}Hi{\\b}"),
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
        let generated = ASSScriptBuilder.script(
            events: SRTToASSConverter.events(from: "1\n00:00:01,000 --> 00:00:02,000\nHi\n\n"),
            fontFamily: "Avenir Next"
        )
        #expect(generated.contains("PlayResX: 1280"))
        #expect(generated.contains("PlayResY: 720"))
        #expect(generated.contains("Style: Default,Avenir Next,48,"))
        // An opaque black ring (BorderStyle 1, Outline 1.92 = 4% of the em) with no
        // shadow, bottom-centre alignment — a converted track looks like normal
        // subtitles even before an override reaches it.
        #expect(generated.contains(",&H00FFFFFF,&H000000FF,&H00000000,&H00000000,"))
        #expect(generated.contains(",1,1.92,0,2,40,40,36,1"))
    }

    /// A comma in the font name would shift every later field of the style line.
    @Test("commas in the font family cannot break the style line")
    func fontNameWithComma() {
        let generated = ASSScriptBuilder.script(
            events: SRTToASSConverter.events(from: "1\n00:00:01,000 --> 00:00:02,000\nHi\n\n"),
            fontFamily: "Bad, Font"
        )
        #expect(generated.contains("Style: Default,Bad Font,48,"))
    }
}
