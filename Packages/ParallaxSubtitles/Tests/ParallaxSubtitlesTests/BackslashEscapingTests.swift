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
