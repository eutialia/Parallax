import Foundation
import Testing

@testable import ParallaxSubtitles

/// libass has no backslash escape. In event text it reads exactly `\N`, `\n`,
/// `\h`, `\{` and `\}` specially; every other `\x` is a literal backslash
/// followed by `x`. So a source backslash cannot be doubled — it has to be
/// emitted once and insulated from whatever follows it, which is what the WORD
/// JOINER after it does (zero-width, non-breaking, drawn by nothing).
@Suite("Backslash handling")
struct BackslashEscapingTests {

    private static let wordJoiner = "\u{2060}"

    /// The whole set libass gives meaning to. Nothing user text contains may
    /// come out of `escape` as one of these by accident.
    private static let libassEscapes: [Character] = ["N", "n", "h", "{", "}"]

    // MARK: - Escaping

    @Test("escaping insulates every source backslash", arguments: [
        ("lone backslash", "\\", "\\\u{2060}"),
        ("windows path that would read as a line break", "C:\\New", "C:\\\u{2060}New"),
        ("backslash before a brace", "\\{x", "\\\u{2060}\\{x"),
        ("doubled backslash", "\\\\", "\\\u{2060}\\\u{2060}"),
    ] as [(String, String, String)])
    func escapeInsulatesBackslashes(label: String, source: String, expected: String) {
        #expect(CueMarkup.escape(source) == expected, "\(label)")
    }

    /// A source backslash is emitted once and always followed by the joiner, so
    /// the character the author wrote after it can never complete an escape.
    @Test("no libass escape can be formed from user text", arguments: libassEscapes)
    func escapesAreUnreachableFromSourceText(escape: Character) {
        let escaped = CueMarkup.escape("\\\(escape)")
        #expect(escaped == "\\\(Self.wordJoiner)" + CueMarkup.escape(String(escape)))
        #expect(SubtitleFontTagger.tokenize(escaped).first == .character("\\"), "\(escaped)")
    }

    @Test("braces and line breaks keep their escapes", arguments: [
        ("open brace", "{", "\\{"),
        ("close brace", "}", "\\}"),
        ("newline", "\n", "\\N"),
        ("plain text is untouched", "Hello, world", "Hello, world"),
    ] as [(String, String, String)])
    func escapeKeepsBraceAndBreakForms(label: String, source: String, expected: String) {
        #expect(CueMarkup.escape(source) == expected, "\(label)")
    }

    // MARK: - Tokenizing

    @Test("only libass' own escapes tokenize as escapes", arguments: [
        ("backslash before CJK", "\\喵", [
            SubtitleFontTagger.Token.character("\\"), .character("喵"),
        ]),
        ("backslash before a letter", "\\x", [.character("\\"), .character("x")]),
        ("trailing backslash", "a\\", [.character("a"), .character("\\")]),
        ("escaped open brace", "\\{", [.escaped("\\{")]),
        ("escaped close brace", "\\}", [.escaped("\\}")]),
        ("hard space", "\\h", [.escaped("\\h")]),
        ("upper line break", "\\N", [.lineBreak("\\N")]),
        ("lower line break", "\\n", [.lineBreak("\\n")]),
        ("word joiner is an ordinary character", "\\\u{2060}", [
            .character("\\"), .character("\u{2060}"),
        ]),
    ] as [(String, String, [SubtitleFontTagger.Token])])
    func tokenizeClassifiesBackslashes(
        label: String, text: String, expected: [SubtitleFontTagger.Token]
    ) {
        #expect(SubtitleFontTagger.tokenize(text) == expected, "\(label)")
    }

    /// A word joiner is `Cf`, so it has no class of its own and stays inside
    /// whichever run is in force — which is the only reason inserting one
    /// cannot split a tagged run in two.
    @Test("the word joiner belongs to the run it sits in")
    func wordJoinerCarriesNoScript() {
        #expect(SubtitleScript.classify("\u{2060}" as Unicode.Scalar) == nil)
    }

    // MARK: - The converted path, end to end

    /// The renderer's converted-subtitle path: convert, plan over the plain
    /// lines, tag every event.
    ///
    /// Both sides read the field through `tokenize`, so a change to what counts
    /// as an escape moves the plan's keys and the tagger's lookups together or
    /// not at all — hence the cache-miss assertion, which is what a drift
    /// between them looks like.
    private func convertedAndTagged(_ body: String, languageHint: String? = nil) -> String {
        var events = SRTToASSConverter.events(from: SRTFixture.text(body))
        let plan = SubtitleFontPlan.build(
            lines: events.flatMap { SubtitleFontTagger.plainLines(of: $0.text) },
            styleFamily: SubtitleFontBundle.sansFamily,
            languageHint: languageHint
        )
        for index in events.indices {
            events[index].text = SubtitleFontTagger.tagged(
                events[index].text, plan: plan, styleFontSize: Double(ASSScriptBuilder.fontSize)
            )
        }
        #expect(plan.cacheMisses.value == 0)
        return events.map(\.text).joined(separator: "\\N")
    }

    /// The reported bug: `\喵/` rendered as `\{\fnNoto Serif CJK SC}▯/`. The
    /// doubled backslash left `\{` for libass to read as a literal brace, so
    /// the whole `\fn` block became text and 喵 stayed on the Latin face.
    @Test("a cue opening with a backslash still gets its CJK run tagged")
    func backslashBeforeCJKDoesNotLeakTheTag() {
        let tagged = convertedAndTagged("\\喵/", languageHint: "zh-Hans")

        #expect(tagged.contains("{\\fnNoto Sans CJK SC"), "\(tagged)")
        #expect(tagged.contains("}喵"), "\(tagged)")
        #expect(!tagged.contains("\\{"), "\(tagged)")
        #expect(tagged.hasPrefix("\\\(Self.wordJoiner){\\fn"), "\(tagged)")
    }

    /// Every `{` in a tagged field is either an override block we wrote or an
    /// escaped source brace — never a `\{` libass would read as literal.
    @Test("every brace in the output is one we meant", arguments: [
        "\\喵/", "{\\fs40}喵", "a {b} 喵", "C:\\New 喵", "\\\\喵",
    ])
    func bracesAreOnlyOverridesOrEscapes(body: String) {
        let tagged = convertedAndTagged(body, languageHint: "zh-Hans")
        let tokens = SubtitleFontTagger.tokenize(tagged)

        for (index, token) in tokens.enumerated() {
            guard case .character(let character) = token, character == "{" else { continue }
            Issue.record("unescaped brace at \(index) in \(tagged)")
        }
        // Escaped braces are only the ones the source really carried.
        let escapedBraces = tokens.filter { $0 == .escaped("\\{") || $0 == .escaped("\\}") }
        #expect(escapedBraces.count == body.filter { $0 == "{" || $0 == "}" }.count, "\(tagged)")
    }

    // MARK: - The authored path

    /// An author's own bare backslash sits in text we did not write, so the
    /// insulation has to be added where the open tag goes in. A Chinese line in
    /// a Japanese-default track is what earns a tag at all: authored CJK that
    /// agrees with the track default is left on the style's own face.
    @Test("an authored backslash before a tagged run is insulated")
    func authoredBackslashGetsAWordJoiner() {
        let plan = SubtitleFontPlan(
            design: .sans,
            styleFamily: SubtitleFontBundle.sansFamily,
            styleFontEmBoxFactor: 1,
            trackDefaultLanguage: .japanese,
            languageByLine: ["\\喵": .simplifiedChinese]
        )
        let tagged = SubtitleFontTagger.authoredTagged("\\喵", plan: plan)

        #expect(tagged == "\\\(Self.wordJoiner){\\fnNoto Sans CJK SC}喵{\\fn}", "\(tagged)")
        #expect(plan.cacheMisses.value == 0)
    }

    @Test("an authored script's backslashed run survives substitution")
    func authoredScriptKeepsItsBackslash() {
        let script = ASSFixture.script(text: "\\สวัสดี/", fontName: "Arial")
        let scan = ASSScriptScan.scan(script: script)
        let plan = SubtitleFontPlan.build(
            lines: scan.plainLines, styleFamily: SubtitleFontBundle.sansFamily, languageHint: nil
        )
        let out = AuthoredFontSubstitution.applied(to: script, plan: plan, scan: scan)
        let text = dialogueText(dialogueLines(out)[0])

        #expect(text == "\\\(Self.wordJoiner){\\fnNoto Sans Thai}สวัสดี{\\fn}/", "\(text)")
        #expect(plan.cacheMisses.value == 0)
    }

    // MARK: - Through libass

    /// Tofu is a successful render, so pixels alone cannot prove this — the
    /// assertion is that libass resolved 喵 to the CJK face by name, with ink
    /// on the canvas to show it drew the cue at all.
    @Test("the reported cue renders its CJK glyph from the CJK face")
    func backslashCueRendersThroughLibass() async throws {
        let renderer = await makeProbeRenderer()
        try await renderer.load(SRTFixture.data(text: "\\喵/"), format: .srt, languageHint: "zh-Hans")
        let frame = try #require(await renderer.frame(at: 2.0))
        _ = try #require(frame.image)
        #expect(try opaqueFraction(of: frame) > 0)

        let log = await renderer.diagnosticLog
        #expect(selected("Noto Sans CJK SC", in: log), "\(fontSelectLines(log))")
        #expect(!log.contains { $0.contains("Using default font") })
    }
}
