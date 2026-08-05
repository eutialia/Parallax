import CoreText
import Foundation
import Testing

@testable import ParallaxSubtitles

/// Language-aware font planning. The defect class this guards against: CoreText
/// resolves a lone Han character through the DEVICE's preferred-languages list,
/// so per-character fallback split one Chinese line across two fonts (different
/// designs, ~20% apart in libass' size normalization) depending on user
/// settings — invisible on the simulator, glaring on a device with Japanese in
/// its language list. The plan pins the choice to the LINE's language instead.
@Suite("CJK font plan")
struct CJKFontPlanTests {

    private static func stubPlan(
        families: [SystemGlyphFont.Language: String],
        sizeFactors: [String: Double] = [:],
        styleFactor: Double = 1,
        trackDefault: SystemGlyphFont.Language = .simplifiedChinese
    ) -> SystemGlyphFont.Plan {
        SystemGlyphFont.Plan(
            subsets: [],
            familyByLanguage: families,
            sizeFactorByFamily: sizeFactors,
            styleFontEmBoxFactor: styleFactor,
            trackDefaultLanguage: trackDefault,
            languageByLine: [:],
            shadowFont: CTFontCreateWithName("Helvetica Neue" as CFString, 24, nil),
            shadowScalars: []
        )
    }

    // MARK: - Scalar classes

    @Test("the CJK gate admits CJK blocks and nothing else")
    func cjkScalarGate() {
        #expect(SystemGlyphFont.isCJKScalar(0x4E00))    // 一
        #expect(SystemGlyphFont.isCJKScalar(0x3042))    // あ
        #expect(SystemGlyphFont.isCJKScalar(0xAC00))    // 가
        #expect(SystemGlyphFont.isCJKScalar(0x3001))    // 、
        #expect(SystemGlyphFont.isCJKScalar(0xFF21))    // fullwidth A
        #expect(SystemGlyphFont.isCJKScalar(0x20BB7))   // ext-B ideograph
        // Emoji, symbols and private use must stay with their own fonts —
        // subsetting a color font yields EMPTY outlines that render as blanks.
        #expect(!SystemGlyphFont.isCJKScalar(0x1F44D))  // 👍
        #expect(!SystemGlyphFont.isCJKScalar(0xFE0F))   // variation selector
        #expect(!SystemGlyphFont.isCJKScalar(0xE000))   // private use
        #expect(!SystemGlyphFont.isCJKScalar(0x2014))   // em dash
    }

    // MARK: - Language detection

    @Test("script-deciding lines detect deterministically under either Chinese default", arguments: [
        ("こんにちは世界", SystemGlyphFont.Language.japanese),      // kana decides
        ("ｱｲｳｴｵ", .japanese),                                       // halfwidth kana too
        ("안녕하세요", .korean),
        ("简体字幕测试", .simplifiedChinese),
        ("這是繁體中文字幕測試", .traditionalChinese),
    ])
    func detectsDecisiveLines(line: String, expected: SystemGlyphFont.Language) {
        // Both Chinese defaults: a decisive line must beat the track default.
        #expect(SystemGlyphFont.language(of: line, trackDefault: .traditionalChinese) == expected)
        #expect(SystemGlyphFont.language(of: line, trackDefault: .simplifiedChinese) == expected)
    }

    @Test("a Japanese track's kanji-only lines are NOT second-guessed as Chinese")
    func kanjiOnlyStaysJapanese() {
        // The recognizer only knows the two Chinese classes, so it scores 東京駅
        // as high-confidence zh-Hant; inside a ja/ko track it must not run.
        #expect(SystemGlyphFont.language(of: "東京駅", trackDefault: .japanese) == .japanese)
        #expect(SystemGlyphFont.language(of: "全員退避", trackDefault: .japanese) == .japanese)
        #expect(SystemGlyphFont.language(of: "漢字", trackDefault: .korean) == .korean)
    }

    @Test("interpunct and prolonged-sound marks do not flip a Chinese line to Japanese")
    func transliterationMarksAreNotDecisive() {
        #expect(SystemGlyphFont.language(of: "赛博・朋克", trackDefault: .simplifiedChinese)
            == .simplifiedChinese)
        #expect(SystemGlyphFont.language(of: "米高ー安积", trackDefault: .simplifiedChinese)
            == .simplifiedChinese)
    }

    @Test("non-CJK lines have no language; CJK-punctuation-only lines take the default")
    func fallbackScope() {
        #expect(SystemGlyphFont.language(of: "Hello 123", trackDefault: .simplifiedChinese) == nil)
        #expect(SystemGlyphFont.language(of: "", trackDefault: .simplifiedChinese) == nil)
        #expect(SystemGlyphFont.language(of: "Nice 👍", trackDefault: .simplifiedChinese) == nil)
        // 「」 are CJK brackets with no Han to detect from — they still need a
        // font, and it must be the track's script, not a per-glyph guess.
        #expect(SystemGlyphFont.language(of: "「…」", trackDefault: .traditionalChinese)
            == .traditionalChinese)
    }

    @Test("track labels map onto languages; bare zh stays undecided", arguments: [
        ("ja", SystemGlyphFont.Language.japanese),
        ("jpn", .japanese),
        ("ko", .korean),
        ("zh-Hant", .traditionalChinese),
        ("zh-TW", .traditionalChinese),
        ("chi-HK", .traditionalChinese),
        ("zh-Hans", .simplifiedChinese),
        ("zh-CN", .simplifiedChinese),
    ])
    func hintMapping(tag: String, expected: SystemGlyphFont.Language) {
        #expect(SystemGlyphFont.Language(hintTag: tag) == expected)
    }

    @Test("undecidable hints map to nothing, and subtags match whole, not by substring")
    func undecidableHints() {
        #expect(SystemGlyphFont.Language(hintTag: "zh") == nil)
        #expect(SystemGlyphFont.Language(hintTag: "en") == nil)
        #expect(SystemGlyphFont.Language(hintTag: nil) == nil)
        // "mong" must not substring-match the "mo" (Macau) region.
        #expect(SystemGlyphFont.Language(hintTag: "zh-mong") == nil)
    }

    @Test("the track default: hint first, then kana/hangul presence, then the Chinese vote")
    func trackDefaultHeuristics() {
        #expect(SystemGlyphFont.trackDefaultLanguage(lines: ["字幕"], hint: "zh-Hant")
            == .traditionalChinese)
        #expect(SystemGlyphFont.trackDefaultLanguage(lines: ["字幕"], hint: "zh-CN")
            == .simplifiedChinese)
        // Kanji-only lines next to kana lines are Japanese, not a zh vote.
        #expect(SystemGlyphFont.trackDefaultLanguage(
            lines: ["こんにちは", "東京駅", "はい"], hint: nil) == .japanese)
        // No kana anywhere: the Han lines vote.
        #expect(SystemGlyphFont.trackDefaultLanguage(
            lines: ["简体字幕测试", "简单的测试"], hint: nil) == .simplifiedChinese)
    }

    // MARK: - Plan resolution (device-family pinning: if these names change,
    // Apple reshuffled system CJK fonts and the whole pipeline needs a re-look)

    @Test("each language resolves to its own coherent system family")
    func languagesResolveCoherently() throws {
        // Han-dominant, so the track defaults to the Chinese vote and the
        // Hans/Hant discriminator runs per line; the kana line stays Japanese.
        // (With kana-dominant lines the track would default to Japanese and
        // JIS-coverable traditional lines would ride the Japanese face — the
        // documented tradeoff, exercised by `dualLanguageCoverageEscape`.)
        let plan = try #require(SystemGlyphFont.plan(
            lines: [
                "简体字幕测试", "简单的第二行", "另一个简体测试行",
                "這是繁體中文字幕測試", "繁體的第二行測試",
                "こんにちは世界",
            ],
            baseFamily: "Helvetica Neue",
            languageHint: nil
        ))
        #expect(plan.familyByLanguage[.simplifiedChinese] == "PingFang SC")
        #expect(plan.familyByLanguage[.traditionalChinese] == "PingFang TC")
        #expect(plan.familyByLanguage[.japanese]?.contains("Hiragino") == true)

        // PingFang's outlines are hvgl (FreeType-unreadable) → synthesized;
        // Hiragino's file is readable → no subset needed.
        let subsetFamilies = Set(plan.subsets.map(\.familyName))
        #expect(subsetFamilies.contains("PingFang SC"))
        #expect(subsetFamilies.contains("PingFang TC"))
        #expect(!subsetFamilies.contains { $0.contains("Hiragino") })

        // Real win boxes from the files: PingFang declares ~1.36 em, Hiragino
        // ~1.12, Helvetica Neue (the style font) ~1.165 — the numbers the `\fs`
        // compensation and the app-side scale mapping neutralize.
        let pingfang = try #require(plan.sizeFactorByFamily["PingFang SC"])
        #expect(abs(pingfang - 1.362) < 0.02)
        let hiragino = try #require(plan.familyByLanguage[.japanese]
            .flatMap { plan.sizeFactorByFamily[$0] })
        #expect(abs(hiragino - 1.123) < 0.02)
        #expect(abs(plan.styleFontEmBoxFactor - 1.165) < 0.02)
        #expect(abs(SubtitleFontMetrics.emBoxFactor(forFamily: "Helvetica Neue") - 1.165) < 0.02)
    }

    @Test("a dual-language track's simplified rows escape the Japanese default via font coverage")
    func dualLanguageCoverageEscape() throws {
        // No hint, kana present → the track defaults to Japanese; the simplified
        // row uses characters no Japanese font carries, which proves it Chinese.
        let plan = try #require(SystemGlyphFont.plan(
            lines: ["こんにちは、日本語のテスト", "简体字幕测试"],
            baseFamily: "Helvetica Neue",
            languageHint: nil
        ))
        #expect(plan.trackDefaultLanguage == .japanese)
        #expect(plan.languageByLine["简体字幕测试"] == .simplifiedChinese)
        #expect(plan.familyByLanguage[.simplifiedChinese] == "PingFang SC")
    }

    @Test("a ja-labeled kanji-only track stays entirely Japanese")
    func jaHintedKanjiTrack() throws {
        let plan = try #require(SystemGlyphFont.plan(
            lines: ["東京駅", "全員退避"],
            baseFamily: "Helvetica Neue",
            languageHint: "ja"
        ))
        #expect(Set(plan.familyByLanguage.keys) == [.japanese])
        #expect(plan.subsets.isEmpty)  // Hiragino's file is FreeType-readable
    }

    @Test("a serif style font routes Japanese through Mincho; Chinese has no serif to go to")
    func serifBaseCascades() throws {
        // The plan resolves through the STYLE font's cascade, so the user's
        // serif choice reaches CJK where the platform has a serif to offer:
        // Japanese (Hiragino Mincho). iOS ships no Chinese serif — those lines
        // stay PingFang, correctly, rather than borrowing Mincho's JIS-only
        // repertoire and reintroducing mixed-font lines.
        let plan = try #require(SystemGlyphFont.plan(
            lines: ["こんにちは世界", "简体字幕测试"],
            baseFamily: "Times New Roman",
            languageHint: nil
        ))
        #expect(plan.familyByLanguage[.japanese] == "Hiragino Mincho ProN")
        #expect(plan.familyByLanguage[.simplifiedChinese] == "PingFang SC")
    }

    @Test("a Latin-only track needs no plan at all")
    func latinTracksSkipPlanning() {
        #expect(SystemGlyphFont.plan(
            lines: ["Hello", "World 123", "emoji 👍 only"],
            baseFamily: "Helvetica Neue", languageHint: nil
        ) == nil)
    }

    // MARK: - Run tagging

    @Test("CJK runs get the plan's family; the reset is bare so style overrides stay in charge")
    func tagsRunsPerLanguage() {
        let plan = Self.stubPlan(families: [.simplifiedChinese: "PingFang SC"])
        let tagged = CJKFontTagger.tagged("简体字幕 ABC 测试", plan: plan, styleFontSize: 48)
        #expect(tagged == "{\\fnPingFang SC}简体字幕{\\fn} ABC {\\fnPingFang SC}测试{\\fn}")
    }

    @Test("a tall win box earns \\fs compensation so an em renders at the style size")
    func compensatesTallWinBoxes() {
        let plan = Self.stubPlan(
            families: [.simplifiedChinese: "PingFang SC"],
            sizeFactors: ["PingFang SC": 1.362]
        )
        let tagged = CJKFontTagger.tagged("简体 ABC", plan: plan, styleFontSize: 48)
        #expect(tagged == "{\\fnPingFang SC\\fs65.4}简体{\\fn\\fs} ABC")
    }

    @Test("compensation is relative to the style font's own box")
    func compensatesRelativeToStyleFont() {
        // The app-side scale already multiplies the style font's box back, so a
        // run only needs the DIFFERENCE: 48 × 1.362 / 1.165 ≈ 56.1.
        let plan = Self.stubPlan(
            families: [.simplifiedChinese: "PingFang SC"],
            sizeFactors: ["PingFang SC": 1.362],
            styleFactor: 1.165
        )
        let tagged = CJKFontTagger.tagged("简体", plan: plan, styleFontSize: 48)
        #expect(tagged == "{\\fnPingFang SC\\fs56.1}简体{\\fn\\fs}")
    }

    @Test("a near-unit factor adds no size tag")
    func skipsNegligibleCompensation() {
        let plan = Self.stubPlan(
            families: [.simplifiedChinese: "PingFang SC"],
            sizeFactors: ["PingFang SC": 1.01]
        )
        #expect(CJKFontTagger.tagged("简体", plan: plan, styleFontSize: 48)
            == "{\\fnPingFang SC}简体{\\fn}")
        // Same box on both sides cancels out entirely.
        let matched = Self.stubPlan(
            families: [.simplifiedChinese: "PingFang SC"],
            sizeFactors: ["PingFang SC": 1.362],
            styleFactor: 1.362
        )
        #expect(CJKFontTagger.tagged("简体", plan: matched, styleFontSize: 48)
            == "{\\fnPingFang SC}简体{\\fn}")
    }

    @Test("each visual line is tagged with its own language's family")
    func tagsPerLine() {
        let plan = Self.stubPlan(families: [
            .simplifiedChinese: "PingFang SC", .japanese: "Hiragino Sans",
        ])
        let tagged = CJKFontTagger.tagged("简体测试\\Nこんにちは", plan: plan, styleFontSize: 48)
        #expect(tagged == "{\\fnPingFang SC}简体测试{\\fn}\\N{\\fnHiragino Sans}こんにちは{\\fn}")
    }

    @Test("override blocks and escapes pass through untouched, outside runs")
    func preservesMarkup() {
        let plan = Self.stubPlan(families: [.simplifiedChinese: "PingFang SC"])
        let tagged = CJKFontTagger.tagged("{\\an8}字\\{幕\\}", plan: plan, styleFontSize: 48)
        #expect(tagged == "{\\an8}{\\fnPingFang SC}字{\\fn}\\{{\\fnPingFang SC}幕{\\fn}\\}")
    }

    @Test("lines with no planned family come back verbatim")
    func leavesUnplannedLinesAlone() {
        let plan = Self.stubPlan(families: [:])
        let text = "{\\i1}Hello\\N简体"
        #expect(CJKFontTagger.tagged(text, plan: plan, styleFontSize: 48) == text)
    }

    // MARK: - Authored script scanning

    @Test("only fonts governing CJK-bearing events are collected, format order respected")
    func collectsCJKFontNames() {
        let script = """
        [V4+ Styles]
        Format: Name, Fontname, Fontsize
        Style: Default,方正准圆_GBK,48
        Format: Fontsize, Fontname, Name
        Style: 20,@DFKai-SB,Vertical
        Style: 20,Open Sans,Eng

        [Events]
        Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
        Dialogue: 0,0:00:01.00,0:00:03.00,Default,,0,0,0,,{\\fnNoto Serif CJK}字幕{\\fn}测试
        Dialogue: 0,0:00:02.00,0:00:04.00,Vertical,,0,0,0,,縦書き
        Dialogue: 0,0:00:03.00,0:00:05.00,Eng,,0,0,0,,English only, with comma
        """
        let scan = ASSScriptScan.scan(script: script)
        // "Open Sans" governs Latin-only text: shadowing it with a CJK-only
        // subset would hijack its English dialogue.
        #expect(scan.cjkFontNames == ["方正准圆_GBK", "DFKai-SB", "Noto Serif CJK"])
        #expect(scan.plainLines.contains("English only, with comma"))
    }

    @Test("dialogue plain lines strip markup and split on breaks")
    func extractsPlainDialogueLines() {
        let script = """
        [Events]
        Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
        Dialogue: 0,0:00:01.00,0:00:03.00,Default,,0,0,0,,{\\an8}第一行\\N第二行, still line two
        """
        #expect(ASSScriptScan.scan(script: script).plainLines == ["第一行", "第二行, still line two"])
    }

    @Test("installed-font check tells real families from silent substitutes")
    func installedFontCheck() {
        #expect(SystemGlyphFont.fontFamilyInstalled("Helvetica Neue"))
        #expect(!SystemGlyphFont.fontFamilyInstalled("方正准圆_GBK"))
    }

    @Test("an hvgl family named directly by a script counts as unusable and shadows from itself")
    func unusableInstalledFamilyShadowsFromItself() throws {
        // "PingFang SC" IS installed — but its file is FreeType-unreadable, so
        // libass can't serve it and the name needs a shadow built from the real
        // PingFang glyphs.
        let font = try #require(SystemGlyphFont.unusableRequestedFont(named: "PingFang SC"))
        #expect((CTFontCopyFamilyName(font) as String) == "PingFang SC")
        // A readable installed family needs nothing.
        #expect(SystemGlyphFont.unusableRequestedFont(named: "Helvetica Neue") == nil)
        // A missing family is not "unusable-installed" — it shadows from the plan.
        #expect(SystemGlyphFont.unusableRequestedFont(named: "方正准圆_GBK") == nil)
    }
}
