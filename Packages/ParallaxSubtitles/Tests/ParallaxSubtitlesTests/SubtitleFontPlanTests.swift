import Foundation
import Testing

@testable import ParallaxSubtitles

/// Font routing over the bundled Noto faces. Two defect classes are guarded
/// here: a run whose script the named family cannot draw (with
/// `ASS_FONTPROVIDER_NONE` that is tofu, not a fallback), and a CJK line drawn
/// from the wrong region's face — every regional face covers the whole Han
/// repertoire, so libass would render a Chinese line out of the Japanese one
/// with no diagnostic anywhere.
@Suite("Subtitle font plan")
struct SubtitleFontPlanTests {

    private static func stubPlan(
        design: SubtitleFontBundle.Design = .sans,
        styleFamily: String? = nil,
        sizeFactors: [String: Double] = [:],
        styleFactor: Double = 1,
        trackDefault: CJKFontPlan.Language? = .simplifiedChinese,
        languageByLine: [String: CJKFontPlan.Language] = [:]
    ) -> SubtitleFontPlan {
        SubtitleFontPlan(
            design: design,
            styleFamily: styleFamily
                ?? SubtitleFontBundle.family(design: design, script: .common),
            styleFontEmBoxFactor: styleFactor,
            trackDefaultLanguage: trackDefault,
            languageByLine: languageByLine,
            sizeFactorByFamily: sizeFactors
        )
    }

    // MARK: - Scalar classes

    @Test("the CJK gate admits CJK blocks and nothing else")
    func cjkScalarGate() {
        #expect(CJKFontPlan.isCJKScalar(0x4E00))    // 一
        #expect(CJKFontPlan.isCJKScalar(0x3042))    // あ
        #expect(CJKFontPlan.isCJKScalar(0xAC00))    // 가
        #expect(CJKFontPlan.isCJKScalar(0x1100))    // ᄀ jamo
        #expect(CJKFontPlan.isCJKScalar(0x3001))    // 、
        #expect(CJKFontPlan.isCJKScalar(0xFF21))    // fullwidth A
        #expect(CJKFontPlan.isCJKScalar(0x20BB7))   // ext-B ideograph
        // Emoji, symbols and private use are not part of a CJK face's design
        // and must not drag a run onto one.
        #expect(!CJKFontPlan.isCJKScalar(0x1F44D))  // 👍
        #expect(!CJKFontPlan.isCJKScalar(0xFE0F))   // variation selector
        #expect(!CJKFontPlan.isCJKScalar(0xE000))   // private use
        #expect(!CJKFontPlan.isCJKScalar(0x2014))   // em dash
    }

    // MARK: - Language detection

    @Test("script-deciding lines detect deterministically under either Chinese default", arguments: [
        ("こんにちは世界", CJKFontPlan.Language.japanese),      // kana decides
        ("ｱｲｳｴｵ", .japanese),                                   // halfwidth kana too
        ("안녕하세요", .korean),
        ("简体字幕测试", .simplifiedChinese),
        ("這是繁體中文字幕測試", .traditionalChinese),
    ])
    func detectsDecisiveLines(line: String, expected: CJKFontPlan.Language) {
        #expect(CJKFontPlan.language(of: line, trackDefault: .traditionalChinese) == expected)
        #expect(CJKFontPlan.language(of: line, trackDefault: .simplifiedChinese) == expected)
    }

    @Test("a Japanese track's kanji-only lines are NOT second-guessed as Chinese")
    func kanjiOnlyStaysJapanese() {
        // The recognizer only knows the two Chinese classes, so it scores 東京駅
        // as high-confidence zh-Hant; inside a ja/ko track it must not run.
        #expect(CJKFontPlan.language(of: "東京駅", trackDefault: .japanese) == .japanese)
        #expect(CJKFontPlan.language(of: "全員退避", trackDefault: .japanese) == .japanese)
        #expect(CJKFontPlan.language(of: "漢字", trackDefault: .korean) == .korean)
    }

    @Test("interpunct and prolonged-sound marks do not flip a Chinese line to Japanese")
    func transliterationMarksAreNotDecisive() {
        #expect(CJKFontPlan.language(of: "赛博・朋克", trackDefault: .simplifiedChinese)
            == .simplifiedChinese)
        #expect(CJKFontPlan.language(of: "米高ー安积", trackDefault: .simplifiedChinese)
            == .simplifiedChinese)
    }

    @Test("non-CJK lines have no language; CJK-punctuation-only lines take the default")
    func fallbackScope() {
        #expect(CJKFontPlan.language(of: "Hello 123", trackDefault: .simplifiedChinese) == nil)
        #expect(CJKFontPlan.language(of: "", trackDefault: .simplifiedChinese) == nil)
        #expect(CJKFontPlan.language(of: "Nice 👍", trackDefault: .simplifiedChinese) == nil)
        // 「」 are CJK brackets with no Han to detect from — they still need a
        // face, and it must be the track's script, not a per-glyph guess.
        #expect(CJKFontPlan.language(of: "「…」", trackDefault: .traditionalChinese)
            == .traditionalChinese)
    }

    @Test("track labels map onto languages; bare zh stays undecided", arguments: [
        ("ja", CJKFontPlan.Language.japanese),
        ("jpn", .japanese),
        ("ko", .korean),
        ("zh-Hant", .traditionalChinese),
        ("zh-TW", .traditionalChinese),
        ("chi-HK", .traditionalChinese),
        ("zh-Hans", .simplifiedChinese),
        ("zh-CN", .simplifiedChinese),
    ])
    func hintMapping(tag: String, expected: CJKFontPlan.Language) {
        #expect(CJKFontPlan.Language(hintTag: tag) == expected)
    }

    @Test("undecidable hints map to nothing, and subtags match whole, not by substring")
    func undecidableHints() {
        #expect(CJKFontPlan.Language(hintTag: "zh") == nil)
        #expect(CJKFontPlan.Language(hintTag: "en") == nil)
        #expect(CJKFontPlan.Language(hintTag: nil) == nil)
        // "mong" must not substring-match the "mo" (Macau) region.
        #expect(CJKFontPlan.Language(hintTag: "zh-mong") == nil)
    }

    @Test("the track default: hint first, then kana/hangul presence, then the Chinese vote")
    func trackDefaultHeuristics() {
        #expect(CJKFontPlan.trackDefaultLanguage(lines: ["字幕"], hint: "zh-Hant")
            == .traditionalChinese)
        #expect(CJKFontPlan.trackDefaultLanguage(lines: ["字幕"], hint: "zh-CN")
            == .simplifiedChinese)
        // Kanji-only lines next to kana lines are Japanese, not a zh vote.
        #expect(CJKFontPlan.trackDefaultLanguage(
            lines: ["こんにちは", "東京駅", "はい"], hint: nil) == .japanese)
        // No kana anywhere: the Han lines vote.
        #expect(CJKFontPlan.trackDefaultLanguage(
            lines: ["简体字幕测试", "简单的测试"], hint: nil) == .simplifiedChinese)
    }

    // MARK: - Plan resolution

    @Test("each language resolves to its own region face of the style's design")
    func languagesResolveCoherently() {
        let plan = SubtitleFontPlan.build(
            lines: [
                "简体字幕测试", "简单的第二行", "另一个简体测试行",
                "這是繁體中文字幕測試", "繁體的第二行測試",
                "こんにちは世界",
            ],
            styleFamily: SubtitleFontBundle.sansFamily,
            languageHint: nil
        )
        #expect(plan.family(forRun: .cjk, line: "简体字幕测试") == "Noto Sans CJK SC")
        #expect(plan.family(forRun: .cjk, line: "這是繁體中文字幕測試") == "Noto Sans CJK TC")
        #expect(plan.family(forRun: .cjk, line: "こんにちは世界") == "Noto Sans CJK JP")

        // Real win boxes, read from the shipped files: the Latin face declares
        // 1.519 em and the CJK collection 1.448, which is what the tagger's \fs
        // compensation and the app-side scale mapping divide by.
        #expect(abs(plan.styleFontEmBoxFactor - 1.519) < 0.001)
        #expect(abs(plan.sizeFactor(forFamily: "Noto Sans CJK SC") - 1.448) < 0.001)
    }

    @Test("a ja-labeled kanji-only track stays entirely Japanese")
    func jaHintedKanjiTrack() {
        let plan = SubtitleFontPlan.build(
            lines: ["東京駅", "全員退避"],
            styleFamily: SubtitleFontBundle.sansFamily,
            languageHint: "ja"
        )
        #expect(plan.trackDefaultLanguage == .japanese)
        #expect(plan.family(forRun: .cjk, line: "東京駅") == "Noto Sans CJK JP")
    }

    @Test("a serif style family plans every region onto the serif collection")
    func serifStyleFamilyPlansSerifRegions() {
        let plan = SubtitleFontPlan.build(
            lines: ["简体字幕测试", "こんにちは世界"],
            styleFamily: SubtitleFontBundle.serifFamily,
            languageHint: "zh-Hans"
        )
        #expect(plan.design == .serif)
        #expect(plan.family(forRun: .cjk, line: "简体字幕测试") == "Noto Serif CJK SC")
        #expect(plan.family(forRun: .cjk, line: "こんにちは世界") == "Noto Serif CJK JP")
    }

    @Test("a Latin-only track plans no CJK default at all")
    func latinTracksSkipCJKPlanning() {
        let plan = SubtitleFontPlan.build(
            lines: ["Hello", "World 123", "emoji 👍 only"],
            styleFamily: SubtitleFontBundle.sansFamily, languageHint: nil
        )
        #expect(plan.trackDefaultLanguage == nil)
        #expect(plan.languageByLine.isEmpty)
        #expect(plan.family(forRun: .common, line: "Hello") == nil)
    }

    @Test("unknown families have no em box to divide by")
    func unknownFamilyMetrics() {
        #expect(SubtitleFontMetrics.emBoxFactor(forFamily: "Arial") == 1)
        #expect(abs(SubtitleFontMetrics.emBoxFactor(forFamily: "Noto Serif CJK KR") - 1.437) < 0.001)
    }

    // MARK: - Script routing

    @Test("each script routes to its own face, in the style's design", arguments: [
        ("สวัสดี", "Noto Sans Thai", "Noto Serif Thai"),
        ("مرحبا", "Noto Naskh Arabic", "Noto Naskh Arabic"),
        ("שלום", "Noto Sans Hebrew", "Noto Serif Hebrew"),
        ("नमस्ते", "Noto Sans Devanagari", "Noto Serif Devanagari"),
        ("নমস্কার", "Noto Sans Bengali", "Noto Serif Bengali"),
        ("வணக்கம்", "Noto Sans Tamil", "Noto Serif Tamil"),
        ("నమస్కారం", "Noto Sans Telugu", "Noto Serif Telugu"),
        ("ಕನ್ನಡ", "Noto Sans Kannada", "Noto Serif Kannada"),
        ("മലയാളം", "Noto Sans Malayalam", "Noto Serif Malayalam"),
        ("ગુજરાતી", "Noto Sans Gujarati", "Noto Serif Gujarati"),
        ("ਪੰਜਾਬੀ", "Noto Sans Gurmukhi", "Noto Serif Gurmukhi"),
        ("සිංහල", "Noto Sans Sinhala", "Noto Serif Sinhala"),
        ("សួស្តី", "Noto Sans Khmer", "Noto Serif Khmer"),
        ("ລາວ", "Noto Sans Lao", "Noto Serif Lao"),
        ("မြန်မာ", "Noto Sans Myanmar", "Noto Serif Myanmar"),
        ("გამარჯობა", "Noto Sans Georgian", "Noto Serif Georgian"),
        ("Բարև", "Noto Sans Armenian", "Noto Serif Armenian"),
    ])
    func scriptsRouteToTheirFace(text: String, sans: String, serif: String) throws {
        for (design, expected) in [(SubtitleFontBundle.Design.sans, sans), (.serif, serif)] {
            let plan = SubtitleFontPlan.build(
                lines: [text],
                styleFamily: SubtitleFontBundle.family(design: design, script: .common),
                languageHint: nil
            )
            let first = try #require(text.first)
            let runClass = try #require(SubtitleScript.classify(first))
            #expect(plan.family(forRun: runClass, line: text) == expected)
        }
    }

    @Test("Latin, Greek and Cyrillic are the style font and take no tag")
    func commonScriptsNeedNoTag() {
        let plan = Self.stubPlan(trackDefault: nil)
        for text in ["İstanbul", "Łódź", "Việt Nam", "Ελληνικά", "Привет"] {
            for character in text {
                let runClass = SubtitleScript.classify(character) ?? .common
                #expect(runClass == .common, "\(character) in \(text)")
            }
            #expect(SubtitleFontTagger.tagged(text, plan: plan, styleFontSize: 48) == text)
        }
    }

    @Test("marks and joiners inherit their base's run; punctuation does not")
    func marksAndJoinersInherit() {
        #expect(SubtitleScript.classify("\u{0E31}" as Unicode.Scalar) == nil)  // Thai vowel sign
        #expect(SubtitleScript.classify("\u{0301}" as Unicode.Scalar) == nil)  // combining acute
        #expect(SubtitleScript.classify("\u{094D}" as Unicode.Scalar) == nil)  // Devanagari virama
        #expect(SubtitleScript.classify("\u{200D}" as Unicode.Scalar) == nil)  // ZWJ
        #expect(SubtitleScript.classify("\u{200C}" as Unicode.Scalar) == nil)  // ZWNJ
        // Punctuation, spaces and digits belong to the Latin face, which is the
        // only one that reliably has them.
        #expect(SubtitleScript.classify(" " as Unicode.Scalar) == .common)
        #expect(SubtitleScript.classify("—" as Unicode.Scalar) == .common)
        #expect(SubtitleScript.classify("·" as Unicode.Scalar) == .common)
        #expect(SubtitleScript.classify("1" as Unicode.Scalar) == .common)
        #expect(SubtitleScript.classify("👍" as Unicode.Scalar) == .common)
        // Full-width CJK punctuation is claimed by the CJK gate before that
        // rule can reach it — a 、 out of the Latin face would be a hole.
        #expect(SubtitleScript.classify("、" as Unicode.Scalar) == .cjk)

        let plan = Self.stubPlan(
            sizeFactors: ["Noto Naskh Arabic": 1, "Noto Sans Devanagari": 1], trackDefault: nil
        )
        // Each Arabic word is its own run and the space between them is Latin;
        // that costs nothing, because Arabic letters do not join across a space
        // and bidi runs over the whole line, not per font run.
        #expect(SubtitleFontTagger.tagged("مرحبا بالعالم", plan: plan, styleFontSize: 48)
            == "{\\fnNoto Naskh Arabic}مرحبا{\\fn} {\\fnNoto Naskh Arabic}بالعالم{\\fn}")
        // A conjunct's virama and ZWJ stay inside the Devanagari run, which is
        // the whole reason marks and joiners are not treated as punctuation.
        #expect(SubtitleFontTagger.tagged("क\u{094D}\u{200D}ष", plan: plan, styleFontSize: 48)
            == "{\\fnNoto Sans Devanagari}क\u{094D}\u{200D}ष{\\fn}")
    }

    /// The block table is searched by bisection, so a row out of order makes the
    /// search silently miss a script — tofu on a device, nothing at all in a
    /// review. These samples walk the table end to end, including every
    /// out-of-sequence extension block.
    @Test("block samples resolve across the whole table", arguments: [
        (UInt32(0x0531), SubtitleFontBundle.Script.armenian),
        (0x05D0, .hebrew), (0x0645, .arabic), (0x0750, .arabic), (0x08A0, .arabic),
        (0x0928, .devanagari), (0x09A8, .bengali), (0x0A28, .gurmukhi),
        (0x0AA8, .gujarati), (0x0BA8, .tamil), (0x0C28, .telugu),
        (0x0CA8, .kannada), (0x0D28, .malayalam), (0x0DA8, .sinhala),
        (0x0E2A, .thai), (0x0EA5, .lao), (0x1019, .myanmar), (0x10D2, .georgian),
        (0x179F, .khmer), (0x19E0, .khmer), (0x1C90, .georgian), (0x2D00, .georgian),
        (0xA8F2, .devanagari), (0xA9E0, .myanmar), (0xAA60, .myanmar),
        (0xFB13, .armenian), (0xFB1D, .hebrew), (0xFB50, .arabic), (0xFEF0, .arabic),
    ])
    func blockSamplesResolve(value: UInt32, script: SubtitleFontBundle.Script) throws {
        let scalar = try #require(Unicode.Scalar(value))
        #expect(
            SubtitleScript.classify(scalar) == .script(script),
            "U+\(String(value, radix: 16, uppercase: true))"
        )
    }

    // MARK: - Run tagging

    @Test("CJK runs get the plan's face; the reset is bare so style overrides stay in charge")
    func tagsRunsPerLanguage() {
        let plan = Self.stubPlan(styleFactor: 1.448)
        let tagged = SubtitleFontTagger.tagged("简体字幕 ABC 测试", plan: plan, styleFontSize: 48)
        #expect(tagged
            == "{\\fnNoto Sans CJK SC}简体字幕{\\fn} ABC {\\fnNoto Sans CJK SC}测试{\\fn}")
    }

    @Test("a taller win box than the style font earns \\fs compensation")
    func compensatesTallWinBoxes() {
        let plan = Self.stubPlan(sizeFactors: ["Noto Sans CJK SC": 1.362])
        let tagged = SubtitleFontTagger.tagged("简体 ABC", plan: plan, styleFontSize: 48)
        #expect(tagged == "{\\fnNoto Sans CJK SC\\fs65.4}简体{\\fn\\fs} ABC")
    }

    @Test("compensation is relative to the style font's own box")
    func compensatesRelativeToStyleFont() {
        // The app-side scale already multiplies the style font's box back, so a
        // run only needs the DIFFERENCE: 48 × 1.362 / 1.165 ≈ 56.1.
        let plan = Self.stubPlan(sizeFactors: ["Noto Sans CJK SC": 1.362], styleFactor: 1.165)
        #expect(SubtitleFontTagger.tagged("简体", plan: plan, styleFontSize: 48)
            == "{\\fnNoto Sans CJK SC\\fs56.1}简体{\\fn\\fs}")
    }

    @Test("a near-unit factor adds no size tag")
    func skipsNegligibleCompensation() {
        let plan = Self.stubPlan(sizeFactors: ["Noto Sans CJK SC": 1.01])
        #expect(SubtitleFontTagger.tagged("简体", plan: plan, styleFontSize: 48)
            == "{\\fnNoto Sans CJK SC}简体{\\fn}")
        let matched = Self.stubPlan(
            sizeFactors: ["Noto Sans CJK SC": 1.448], styleFactor: 1.448
        )
        #expect(SubtitleFontTagger.tagged("简体", plan: matched, styleFontSize: 48)
            == "{\\fnNoto Sans CJK SC}简体{\\fn}")
    }

    /// The real bundle's numbers, not stubs: Myanmar declares a 2.50 em box
    /// against the Latin face's 1.519, so an uncompensated Myanmar caption
    /// renders at 61% of the Latin around it.
    @Test("a real Myanmar run is compensated against the real Latin style box")
    func compensatesRealScriptBoxes() {
        let plan = SubtitleFontPlan.build(
            lines: ["မြန်မာ"], styleFamily: SubtitleFontBundle.serifFamily, languageHint: nil
        )
        let tagged = SubtitleFontTagger.tagged("မြန်မာ", plan: plan, styleFontSize: 48)
        #expect(tagged.hasPrefix("{\\fnNoto Serif Myanmar\\fs"))
        // 48 × 2.499 / 1.458 ≈ 82.3
        #expect(tagged.contains("\\fs82."), "\(tagged)")
    }

    @Test("each visual line is tagged with its own language's face")
    func tagsPerLine() {
        let plan = Self.stubPlan(styleFactor: 1.448)
        let tagged = SubtitleFontTagger.tagged("简体测试\\Nこんにちは", plan: plan, styleFontSize: 48)
        #expect(tagged
            == "{\\fnNoto Sans CJK SC}简体测试{\\fn}\\N{\\fnNoto Sans CJK JP}こんにちは{\\fn}")
    }

    @Test("override blocks and escapes pass through untouched, outside runs")
    func preservesMarkup() {
        let plan = Self.stubPlan(styleFactor: 1.448)
        let tagged = SubtitleFontTagger.tagged("{\\an8}字\\{幕\\}", plan: plan, styleFontSize: 48)
        #expect(tagged
            == "{\\an8}{\\fnNoto Sans CJK SC}字{\\fn}\\{{\\fnNoto Sans CJK SC}幕{\\fn}\\}")
    }

    @Test("lines with nothing but Latin come back verbatim")
    func leavesCommonLinesAlone() {
        let plan = Self.stubPlan()
        let text = "{\\i1}Hello World"
        #expect(SubtitleFontTagger.tagged(text, plan: plan, styleFontSize: 48) == text)
    }

    @Test("authored tagging skips CJK lines that agree with the default, never other scripts")
    func authoredTaggingScope() {
        let plan = Self.stubPlan(trackDefault: .simplifiedChinese)
        // The Chinese line already renders from the style's face — tagging it
        // would rewrite someone else's document to no effect.
        #expect(SubtitleFontTagger.authoredTagged("简体字幕", plan: plan) == "简体字幕")
        #expect(SubtitleFontTagger.authoredTagged("こんにちは", plan: plan)
            == "{\\fnNoto Sans CJK JP}こんにちは{\\fn}")
        // A Thai run has no such escape: no substituted style can draw it.
        #expect(SubtitleFontTagger.authoredTagged("สวัสดี", plan: plan)
            == "{\\fnNoto Sans Thai}สวัสดี{\\fn}")
        // And it never touches sizes: those are the author's.
        let serif = Self.stubPlan(design: .serif, sizeFactors: ["Noto Serif CJK JP": 1.9])
        #expect(SubtitleFontTagger.authoredTagged("こんにちは", plan: serif)
            == "{\\fnNoto Serif CJK JP}こんにちは{\\fn}")
    }

    // MARK: - Authored script scanning

    @Test("dialogue plain lines strip markup and split on breaks")
    func extractsPlainDialogueLines() {
        let script = """
        [Events]
        Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
        Dialogue: 0,0:00:01.00,0:00:03.00,Default,,0,0,0,,{\\an8}第一行\\N第二行, still line two
        """
        #expect(ASSScriptScan.scan(script: script).plainLines == ["第一行", "第二行, still line two"])
    }

    // MARK: - Authored font substitution

    /// Substring containment gets this wrong in both directions: "serif" hits
    /// "MS Sans Serif", "ming" hits "Flaming", "song" hits any Latin family
    /// carrying it. The rule is `sans` first and unconditionally, CJK markers as
    /// substrings (they have no word boundaries), Latin markers on whole tokens
    /// of the camel-split name (`STSong` → st|song, `PMingLiU` → p|ming|li|u).
    @Test("author font names route by serif intent", arguments: [
        // Sans, including the four a substring test used to misroute.
        ("Arial", SubtitleFontBundle.Design.sans),
        ("MS Sans Serif", .sans),
        ("Comic Sans MS", .sans),
        ("Flaming Text", .sans),
        ("Microsoft YaHei", .sans),
        ("微軟正黑體", .sans),
        ("FZLanTingHei", .sans),
        ("SimHei", .sans),
        ("MS PGothic", .sans),
        ("方正准圆_GBK", .sans),
        ("PingFang SC", .sans),
        ("DFKai-SB", .sans),
        // Serif.
        ("MS Mincho", .serif),
        ("ＭＳ 明朝", .serif),
        ("Hiragino Mincho ProN", .serif),
        ("Noto Serif CJK", .serif),
        ("Times New Roman", .serif),
        ("SimSun", .serif),
        ("NSimSun", .serif),
        ("STSong", .serif),
        ("PMingLiU", .serif),
        ("宋体", .serif),
        ("細明體", .serif),
    ])
    func serifIntentRouting(name: String, expected: SubtitleFontBundle.Design) {
        #expect(AuthoredFontSubstitution.design(forAuthoredName: name) == expected)
    }

    @Test("style and inline font names are substituted; every other field survives")
    func substitutesFontNamesOnly() {
        let script = ASSFixture.script(text: "{\\fnMS Mincho}字幕{\\fn}测试", fontName: "Arial")
        let plan = SubtitleFontPlan.build(
            lines: ["字幕测试"], styleFamily: SubtitleFontBundle.sansFamily, languageHint: "zh-Hans"
        )
        let out = AuthoredFontSubstitution.applied(to: script, plan: plan)

        #expect(out.contains("Style: Default,Noto Sans CJK SC,28,&H00FFFFFF,"))
        #expect(!out.contains("Arial"))
        // The author's serif intent survives the substitution; the bare reset
        // stays bare so it still reverts to the style's font.
        #expect(dialogueText(dialogueLines(out)[0])
            == "{\\fnNoto Serif CJK SC}字幕{\\fn}测试")
        // Untouched: canvas, colours, geometry.
        #expect(out.contains("PlayResX: 640"))
        #expect(out.contains(",&H000000FF,&H00000000,&H00000000,0,0,0,0,100,100,0,0,1,"))
    }

    /// The typeface is the ONLY thing we take from an authored script, and the
    /// AUTHOR picks it: their serif intent decides, not the user's Sans/Serif
    /// setting — the plan here is built on the sans family (what the app always
    /// hands an authored track) and the Mincho style still lands on Noto Serif.
    /// Every other line of the script has to come back byte-identical.
    @Test("an authored style keeps every field and every other line; only its font name moves")
    func authoredSubstitutionTouchesNothingButTheFontName() throws {
        let script = ASSFixture.script(text: "Hello, world", fontName: "MS Mincho")
        let plan = SubtitleFontPlan.build(
            lines: ["Hello, world"], styleFamily: SubtitleFontBundle.sansFamily, languageHint: nil
        )
        let out = AuthoredFontSubstitution.applied(to: script, plan: plan)

        func styleFields(_ text: String) throws -> [String] {
            let line = try #require(text.split(separator: "\n").first { $0.hasPrefix("Style: ") })
            return line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        }
        let before = try styleFields(script)
        let after = try styleFields(out)
        #expect(after[1] == SubtitleFontBundle.serifFamily)
        #expect(before.indices.filter { before[$0] != after[$0] } == [1])

        let others = { (text: String) in text.split(separator: "\n").filter { !$0.hasPrefix("Style: ") } }
        #expect(others(out) == others(script))
    }

    @Test("a serif style keeps its design when a divergent line gets a region face")
    func regionTagsPreserveStyleDesign() {
        let script = ASSFixture.script(text: "こんにちは", fontName: "MS Mincho")
        let plan = SubtitleFontPlan.build(
            lines: ["简体字幕", "こんにちは"],
            styleFamily: SubtitleFontBundle.sansFamily, languageHint: "zh-Hans"
        )
        let out = AuthoredFontSubstitution.applied(to: script, plan: plan)

        // zh-Hans default → the style lands on the Serif SC face…
        #expect(out.contains("Style: Default,Noto Serif CJK SC,28,"))
        // …and the kana line diverges, onto the Japanese SERIF face, not Sans.
        #expect(dialogueText(dialogueLines(out)[0]) == "{\\fnNoto Serif CJK JP}こんにちは{\\fn}")
    }

    @Test("a Latin-only authored script lands on the Latin face, not a CJK one")
    func latinAuthoredScriptSubstitutes() {
        let script = ASSFixture.script(text: "Hello, world", fontName: "Comic Sans MS")
        let plan = SubtitleFontPlan.build(
            lines: ["Hello, world"], styleFamily: SubtitleFontBundle.sansFamily, languageHint: nil
        )
        let out = AuthoredFontSubstitution.applied(to: script, plan: plan)
        #expect(out.contains("Style: Default,Noto Sans,28,"))
        #expect(dialogueText(dialogueLines(out)[0]) == "Hello, world")
    }

    @Test("an authored Thai script keeps its Latin style and tags the Thai runs")
    func thaiAuthoredScriptRoutes() {
        let script = ASSFixture.script(text: "สวัสดี OK", fontName: "Tahoma")
        let plan = SubtitleFontPlan.build(
            lines: ["สวัสดี OK"], styleFamily: SubtitleFontBundle.sansFamily, languageHint: nil
        )
        let out = AuthoredFontSubstitution.applied(to: script, plan: plan)
        #expect(out.contains("Style: Default,Noto Sans,28,"))
        #expect(dialogueText(dialogueLines(out)[0]).contains("{\\fnNoto Sans Thai}"))
    }

    /// A CRLF script's `\r` belongs to the line, not to its last field. Carried
    /// into the Text field it misses `languageByLine` (keyed on trimmed lines),
    /// and every cue silently pays for a fresh `NLLanguageRecognizer` — invisible
    /// in the output, expensive on a 3000-cue track.
    @Test("every dialogue line of a CRLF script hits the plan's language cache")
    func crlfDialogueLinesHitThePlanCache() {
        let dialogue = ["简体字幕测试", "第二行也是中文", "Latin only"]
        func script(separator: String) -> String {
            ([
                "[V4+ Styles]",
                "Format: Name, Fontname, Fontsize",
                "Style: Default,Arial,28",
                "",
                "[Events]",
                "Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text",
            ] + dialogue.map { "Dialogue: 0,0:00:01.00,0:00:03.00,Default,,0,0,0,,\($0)" })
                .joined(separator: separator)
        }

        for separator in ["\r\n", "\n"] {
            let plan = SubtitleFontPlan.build(
                lines: dialogue, styleFamily: SubtitleFontBundle.sansFamily, languageHint: "zh-Hans"
            )
            _ = AuthoredFontSubstitution.applied(to: script(separator: separator), plan: plan)
            #expect(plan.cacheMisses.value == 0, "separator \(separator.debugDescription)")
        }

        // …and the counter is not vacuously zero: a line the plan never saw is
        // exactly what it exists to catch.
        let plan = SubtitleFontPlan.build(
            lines: dialogue, styleFamily: SubtitleFontBundle.sansFamily, languageHint: "zh-Hans"
        )
        _ = plan.family(forRun: .cjk, line: "未曾見過的一行")
        #expect(plan.cacheMisses.value == 1)
    }

    @Test("CRLF line endings and non-default Format column orders survive")
    func preservesScriptShape() {
        // Swift reads CRLF as ONE Character, so a naive line split hands the
        // whole script back as a single line and substitutes nothing. Most
        // authored scripts are CRLF.
        func script(font: String) -> String {
            [
                "[V4+ Styles]",
                "Format: Fontsize, Fontname, Name",
                "Style: 20,\(font),Vertical",
                "",
                "[Events]",
                "Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text",
                "Dialogue: 0,0:00:01.00,0:00:03.00,Vertical,,0,0,0,,縦書き",
            ].joined(separator: "\r\n")
        }
        let plan = SubtitleFontPlan.build(
            lines: ["縦書き"], styleFamily: SubtitleFontBundle.sansFamily, languageHint: "ja"
        )
        // The style names the JP face, so the line agrees with the default and
        // takes no tag — the script comes back with only its Fontname changed.
        #expect(AuthoredFontSubstitution.applied(to: script(font: "@DFKai-SB"), plan: plan)
            == script(font: "Noto Sans CJK JP"))
    }

    // MARK: - Symbol routing by coverage

    /// ♪ and friends are ordinary in subtitles and absent from the Latin faces.
    /// With every system provider off there is no per-glyph fallback to save
    /// them, so the answer has to come from the files: whichever bundled face
    /// has the glyph, preferring the CJK collection of the track's own region.
    @Test("symbols the style face lacks are routed to a face that has them", arguments: [
        "♪", "♫", "♥", "★", "→", "●", "▶", "∞",
    ])
    func symbolsRouteByCoverage(symbol: String) throws {
        let scalar = try #require(symbol.unicodeScalars.first)
        // The premise: the Latin style faces really cannot draw these.
        #expect(!SubtitleFontBundle.covers(scalar.value, family: "Noto Sans"))
        #expect(!SubtitleFontBundle.covers(scalar.value, family: "Noto Serif"))

        for design in SubtitleFontBundle.Design.allCases {
            let plan = Self.stubPlan(design: design)
            let routed = try #require(
                SubtitleScript.classify(scalar, routing: plan.symbolRouting),
                "\(symbol) unclassified"
            )
            guard case .symbol(let family) = routed else {
                Issue.record("\(symbol)/\(design) classified \(routed)")
                continue
            }
            #expect(family == SubtitleFontBundle.family(
                design: design, script: .cjk(.simplifiedChinese)
            ))
            #expect(SubtitleFontBundle.covers(scalar.value, family: family))
        }
    }

    /// Guillemets are in the Latin faces, so nothing may move them: routing a
    /// covered scalar off the style font would change how ordinary punctuation
    /// is drawn for no reason.
    @Test("a symbol the style face already covers is left alone", arguments: ["«", "»", "—", "·"])
    func coveredSymbolsStayOnTheStyleFace(symbol: String) throws {
        let scalar = try #require(symbol.unicodeScalars.first)
        #expect(SubtitleFontBundle.covers(scalar.value, family: "Noto Sans"))
        #expect(SubtitleScript.classify(scalar, routing: Self.stubPlan().symbolRouting) == .common)
    }

    /// Emoji are not in any bundled Noto file, and routing cannot invent them —
    /// they stay the style face's .notdef. Documented as unsupported rather
    /// than silently smuggled into a CJK face that also lacks them.
    @Test("emoji are unsupported: nothing in the bundle claims them")
    func emojiAreUnsupported() throws {
        let scalar = try #require("😀".unicodeScalars.first)
        #expect(SubtitleScript.classify(scalar, routing: Self.stubPlan().symbolRouting) == .common)
    }

    @Test("consecutive symbols answering to one face stay one run")
    func symbolRunsCoalesce() {
        let runs = scriptRuns(of: "♪♫", routing: Self.stubPlan().symbolRouting)
        #expect(runs.count == 1)
    }

    /// The tag has to name the face and the closer has to give the run back, or
    /// the rest of the line renders from the CJK face's Latin design.
    @Test("a converted cue wraps its symbols and closes back to the style font")
    func convertedSymbolsAreTagged() {
        let plan = Self.stubPlan(trackDefault: nil)
        let out = SubtitleFontTagger.tagged("♪ La la la", plan: plan, styleFontSize: 48)
        #expect(out.hasPrefix("{\\fnNoto Sans CJK JP"))
        #expect(out.contains("{\\fn\\fs} La la la") || out.contains("{\\fn} La la la"), "\(out)")
    }

    // MARK: - Authored styles

    /// The deleted CJK scan's rule, restored: a style is moved onto the track's
    /// CJK face only if it governs a line that actually has CJK in it. A
    /// fansub's English signs style used by nothing but Latin lines stays on
    /// the Latin face — moving it renders every one of those lines in the CJK
    /// face's Latin design.
    @Test("a Latin-only style in a CJK track keeps a Latin face")
    func latinOnlyStyleKeepsLatinFace() {
        let script = [
            "[Script Info]",
            "ScriptType: v4.00+",
            "",
            "[V4+ Styles]",
            "Format: Name, Fontname, Fontsize",
            "Style: Default,SimHei,28",
            "Style: Eng,Open Sans,24",
            "Style: Sign,Times New Roman,24",
            "",
            "[Events]",
            "Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text",
            "Dialogue: 0,0:00:01.00,0:00:03.00,Default,,0,0,0,,简体字幕测试",
            "Dialogue: 0,0:00:01.00,0:00:03.00,Eng,,0,0,0,,Hello there",
            "Dialogue: 0,0:00:04.00,0:00:06.00,Sign,,0,0,0,,Chapter One",
        ].joined(separator: "\n")

        let plan = SubtitleFontPlan.build(
            lines: ["简体字幕测试", "Hello there", "Chapter One"],
            styleFamily: SubtitleFontBundle.sansFamily, languageHint: "zh-Hans"
        )
        let out = AuthoredFontSubstitution.applied(to: script, plan: plan)

        #expect(out.contains("Style: Default,Noto Sans CJK SC,28"))
        #expect(out.contains("Style: Eng,Noto Sans,24"))
        // Serif intent survives on a Latin-only style too.
        #expect(out.contains("Style: Sign,Noto Serif,24"))
        // And the Latin lines take no tag at all.
        #expect(dialogueText(dialogueLines(out)[1]) == "Hello there")
        #expect(dialogueText(dialogueLines(out)[2]) == "Chapter One")
    }

    /// Closing a tagged run with a bare `{\fn}` throws away the author's own
    /// `\fn` for the rest of the line: libass reverts to the STYLE font, and
    /// the italic/handwriting face the author asked for silently stops.
    @Test("an authored run closes back to the author's in-force font")
    func authoredRunRestoresTheAuthorsFont() {
        let plan = SubtitleFontPlan.build(
            lines: ["English สวัสดี English"],
            styleFamily: SubtitleFontBundle.sansFamily, languageHint: nil
        )
        let tagged = SubtitleFontTagger.authoredTagged(
            "{\\fnNoto Serif}English สวัสดี English", plan: plan
        )
        #expect(tagged.contains("{\\fnNoto Sans Thai}"))
        #expect(tagged.contains("{\\fnNoto Serif}สวัสดี") == false)
        // The closer names the font the author had in force, not a bare reset.
        #expect(tagged.hasSuffix("{\\fnNoto Serif} English"), "\(tagged)")
    }

    @Test("a converted cue still closes with the bare reset")
    func convertedRunKeepsTheBareReset() {
        let plan = SubtitleFontPlan.build(
            lines: ["สวัสดี ok"], styleFamily: SubtitleFontBundle.sansFamily, languageHint: nil
        )
        let tagged = SubtitleFontTagger.tagged("สวัสดี ok", plan: plan, styleFontSize: 48)
        #expect(tagged.contains("{\\fn\\fs} ok") || tagged.contains("{\\fn} ok"), "\(tagged)")
    }

    @Test("a bare inline reset leaves the closer bare")
    func bareResetStaysBare() {
        let plan = SubtitleFontPlan.build(
            lines: ["สวัสดี ok"], styleFamily: SubtitleFontBundle.sansFamily, languageHint: nil
        )
        let tagged = SubtitleFontTagger.authoredTagged("{\\fnArial}{\\fn}สวัสดี ok", plan: plan)
        #expect(tagged.contains("{\\fnNoto Sans Thai}สวัสดี{\\fn}"), "\(tagged)")
    }

    /// The `Text` field of a Dialogue keeps whatever trailing whitespace the
    /// author left; the scan trims the whole line before splitting it. Keyed on
    /// different strings, every such cue silently re-runs language detection.
    @Test("a dialogue line with trailing whitespace still hits the plan cache")
    func trailingWhitespaceHitsThePlanCache() {
        let script = [
            "[V4+ Styles]",
            "Format: Name, Fontname, Fontsize",
            "Style: Default,SimHei,28",
            "",
            "[Events]",
            "Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text",
            "Dialogue: 0,0:00:01.00,0:00:03.00,Default,,0,0,0,,简体字幕测试   ",
        ].joined(separator: "\n")

        let scan = ASSScriptScan.scan(script: script)
        let plan = SubtitleFontPlan.build(
            lines: scan.plainLines,
            styleFamily: SubtitleFontBundle.sansFamily, languageHint: "zh-Hans"
        )
        _ = AuthoredFontSubstitution.applied(to: script, plan: plan, scan: scan)
        #expect(plan.cacheMisses.value == 0)
    }

    // MARK: - Which files a track needs

    /// What the lazy registration is driven by. An English track must not pull
    /// the 19 MB pan-CJK collection into a library that never releases it.
    @Test("a track's families decide which files are registered")
    func filesFollowTheFamilies() {
        let latin = SubtitleFontBundle.files(forFamilies: ["Noto Sans"])
            .map(\.lastPathComponent)
        #expect(Set(latin) == Set(SubtitleFontBundle.latinFileNames))

        let chinese = SubtitleFontBundle.files(forFamilies: ["Noto Sans", "Noto Sans CJK SC"])
            .map(\.lastPathComponent)
        #expect(Set(chinese) == Set(SubtitleFontBundle.latinFileNames + [
            "NotoSansCJK-Regular.ttc", "NotoSerifCJK-Regular.ttc",
        ]))

        // A name nothing in the bundle carries adds no file: libass resolves it
        // through default_family, which is one of the Latin pair.
        #expect(SubtitleFontBundle.files(forFamilies: ["Comic Sans MS"]).map(\.lastPathComponent)
            == SubtitleFontBundle.latinFileNames.sorted())
    }

    @Test("the families a finished script asks for are read back off it")
    func requestedFamiliesAreReadOffTheScript() {
        let script = ASSFixture.script(
            text: "{\\fnNoto Sans Thai}สวัสดี{\\fn}ok", fontName: "Noto Serif"
        )
        #expect(ASSScriptScan.requestedFamilies(in: script)
            == ["Noto Serif", "Noto Sans Thai"])
    }
}
