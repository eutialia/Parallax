import Foundation
import Testing

@testable import ParallaxSubtitles

/// Font resolution through the full render path. Tofu is a *successful* render
/// of .notdef boxes and a wrong-region glyph is a successful render of the
/// wrong shape, so pixels can't catch either — libass' captured font-selection
/// log is the assertion surface.
///
/// What this suite exists to prevent: the per-glyph fallback lottery. libass
/// resolves a glyph its current font lacks by asking a provider one codepoint
/// at a time, with no language context, so the answer used to track the
/// device's preferred-languages list. With `ASS_FONTPROVIDER_NONE` there is
/// nothing to ask — every resolution must be a direct family match against a
/// face we shipped, which is only true if routing named it first.
@Suite("Script render fallback")
struct ScriptRenderProbeTests {

    /// Han-FIRST text is the poison case: it is the first glyph to miss, and
    /// under the old design it decided the whole cue's font.
    private static let hanFirstSRT = SRTFixture.text("這是繁體中文字幕測試\n简体字幕测试 ABC123")

    @Test("a Chinese-first SRT resolves every glyph by family — no fallback, no default")
    func chineseFirstSRTResolvesByFamily() async throws {
        let renderer = await makeProbeRenderer()
        try await renderer.load(Data(Self.hanFirstSRT.utf8), format: .srt)
        let frame = try #require(await renderer.frame(at: 2.0))
        _ = try #require(frame.image)
        #expect(try opaqueFraction(of: frame) > 0)

        let log = await renderer.diagnosticLog
        _ = try requireFontSelections(log)
        #expect(!log.contains { $0.contains("failed to find any fallback") })
        // One "selecting one more font" means the per-glyph lottery is back.
        #expect(!log.contains { $0.contains("selecting one more font") })
        // Nothing may reach default_family either: every name in a converted
        // script is one we wrote and one we shipped.
        #expect(!log.contains { $0.contains("Using default font") })
        // And the bare {\fn} reset must revert to the STYLE font, not request
        // an empty family for the Latin tail.
        #expect(!log.contains { $0.contains("fontselect: (,") })
    }

    /// Every negative log assertion in this suite is worthless if the log is
    /// empty — a renderer that logged nothing "contains no fallback line" too.
    /// So each one is paired with this: libass really did report its font
    /// selections for the render just made.
    private func requireFontSelections(_ log: [String]) throws -> [String] {
        let selections = fontSelectLines(log)
        #expect(!log.isEmpty)
        try #require(!selections.isEmpty, "no fontselect line in \(log)")
        return selections
    }

    /// The all-Noto bundle's version of the same guard, and the one that could
    /// not pass before routing existed: one SRT carrying nine writing systems,
    /// none of which any single bundled file covers. Every glyph must still be
    /// resolved by a direct family match — no fallback search, no
    /// `default_family`, no empty request from a bare `{\fn}` reset.
    @Test("a nine-script SRT resolves every run by family", arguments: SubtitleFontBundle.Design.allCases)
    func mixedScriptSRTResolvesByFamily(design: SubtitleFontBundle.Design) async throws {
        let renderer = await makeProbeRenderer(
            fontFamily: SubtitleFontBundle.family(design: design, script: .common)
        )
        let srt = SRTFixture.text(
            """
            ♪ The quick brown fox ♪ — 字幕測試 ★
            สวัสดี · مرحبا بالعالم · שלום · « → »
            नमस्ते दुनिया · வணக்கம் · నమస్కారం · ● ▶
            გამარჯობა · Բարև · Việt Nam · ♥ ♫
            """
        )
        try await renderer.load(Data(srt.utf8), format: .srt)
        let frame = try #require(await renderer.frame(at: 2.0))
        _ = try #require(frame.image)
        #expect(try opaqueFraction(of: frame) > 0)

        let log = await renderer.diagnosticLog
        #expect(!log.contains { $0.contains("failed to find any fallback") })
        #expect(!log.contains { $0.contains("selecting one more font") })
        #expect(!log.contains { $0.contains("Using default font") })
        #expect(!log.contains { $0.contains("fontselect: (,") })

        // And the resolutions really are the per-script faces, not one file
        // silently answering for everything.
        let selections = try requireFontSelections(log)
        for family in [
            "Noto Sans Thai", "Noto Naskh Arabic", "Noto Sans Hebrew",
            "Noto Sans Devanagari", "Noto Sans Tamil", "Noto Sans Telugu",
            "Noto Sans Georgian", "Noto Sans Armenian",
        ] {
            let expected = design == .serif && family != "Noto Naskh Arabic"
                ? family.replacingOccurrences(of: "Noto Sans", with: "Noto Serif")
                : family
            #expect(selected(expected, in: log), "\(expected) missing from \(selections)")
        }
    }

    @Test("a Japanese line and a Chinese line in one track take different region faces")
    func regionsSplitWithinOneTrack() async throws {
        let renderer = await makeProbeRenderer()
        let srt = """
        1
        00:00:01,000 --> 00:00:03,000
        简体字幕测试

        2
        00:00:01,000 --> 00:00:03,000
        こんにちは世界

        """
        try await renderer.load(Data(srt.utf8), format: .srt, languageHint: "zh-Hans")
        _ = try #require(await renderer.frame(at: 2.0))

        let log = await renderer.diagnosticLog
        #expect(selected("Noto Sans CJK SC", in: log))
        #expect(selected("Noto Sans CJK JP", in: log))
        #expect(!log.contains { $0.contains("Using default font") })
    }

    @Test("an authored script's Arial renders Sans, its Mincho renders Serif")
    func authoredNamesRouteBySerifIntent() async throws {
        let sans = await makeProbeRenderer()
        try await sans.load(ASSFixture.data(text: "字幕測試 ABC", fontName: "Arial"), format: .ass)
        _ = try #require(await sans.frame(at: 2.0))
        let sansLog = await sans.diagnosticLog
        #expect(!sansLog.contains { $0.contains("Arial") })
        #expect(fontSelectLines(sansLog).contains { $0.contains("NotoSansCJK") })
        #expect(!fontSelectLines(sansLog).contains { $0.contains("NotoSerifCJK") })

        let serif = await makeProbeRenderer()
        try await serif.load(ASSFixture.data(text: "字幕測試 ABC", fontName: "MS Mincho"), format: .ass)
        _ = try #require(await serif.frame(at: 2.0))
        let serifLog = await serif.diagnosticLog
        #expect(!serifLog.contains { $0.contains("Mincho") })
        #expect(fontSelectLines(serifLog).contains { $0.contains("NotoSerifCJK") })
        #expect(!fontSelectLines(serifLog).contains { $0.contains("NotoSansCJK") })
    }

    @Test("no system font is reachable: a requested system family falls to default_family")
    func fontProviderNoneIsInEffect() async throws {
        // The style override is the one channel that can still put an arbitrary
        // family in front of libass — it writes FontName straight into the
        // override style, past every substitution. With the system provider off
        // it must resolve to a bundled face, not to the installed one.
        let renderer = await makeProbeRenderer()
        await renderer.setStyleOverride(SubtitleStyleOverride(fontFamily: unreachableSystemFamily))
        try await renderer.load(SRTFixture.data(text: "Hello world"), format: .srt)
        _ = try #require(await renderer.frame(at: 2.0))

        let log = await renderer.diagnosticLog
        #expect(log.contains { $0.contains("Using default font family") })
        #expect(fontSelectLines(log).contains {
            $0.contains(unreachableSystemFamily) && $0.contains("NotoSans-Regular")
        })
        #expect(!log.contains { $0.contains("failed to find any fallback") })
    }

    /// Legacy fansub encodings are decoded and re-emitted as UTF-8 instead of
    /// being handed to libass' iconv path: raw, the substitution pre-pass cannot
    /// parse them, so every style collapses onto `default_family` and every line
    /// onto the Latin face, which has no Han at all — exactly the lottery the
    /// bundle exists to end.
    @Test("a legacy-encoded authored script is decoded, planned and routed", arguments: [
        (
            "GBK", CFStringEncodings.GB_18030_2000, "SimHei",
            "简体中文字幕测试\n这是第二行的文字", "Noto Sans CJK SC"
        ),
        (
            "Big5", CFStringEncodings.big5, "MingLiU",
            "繁體中文字幕測試\n這是第二行的文字", "Noto Serif CJK TC"
        ),
        (
            "Shift_JIS", CFStringEncodings.dosJapanese, "MS Gothic",
            "日本語の字幕テストです\nこれは二行目の文字", "Noto Sans CJK JP"
        ),
    ])
    func legacyEncodedScriptsAreDecoded(
        name: String, encoding: CFStringEncodings, fontName: String,
        text: String, expectedFamily: String
    ) async throws {
        let script = ASSFixture.script(
            text: text.replacingOccurrences(of: "\n", with: "\\N"), fontName: fontName
        )
        let legacy = try #require(script.data(
            using: String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
                CFStringEncoding(encoding.rawValue)
            ))
        ))
        #expect(String(data: legacy, encoding: .utf8) == nil, "\(name) fixture is not UTF-8")

        let renderer = await makeProbeRenderer()
        try await renderer.load(legacy, format: .ass)
        let frame = try #require(await renderer.frame(at: 2.0))
        _ = try #require(frame.image)
        #expect(try opaqueFraction(of: frame) > 0)

        let log = await renderer.diagnosticLog
        #expect(selected(expectedFamily, in: log), "\(name): \(fontSelectLines(log))")
        #expect(!log.contains { $0.contains("failed to find any fallback") })
    }

    /// Sniffing cannot be done on bytes alone — Big5 text is almost entirely
    /// VALID GB18030, and decoding it that way yields plausible-looking Han with
    /// no replacement character anywhere. The decode is scored on the language
    /// the resulting DIALOGUE reads as, which is what separates them.
    @Test("legacy encodings are told apart by what they decode to", arguments: [
        ("繁體中文字幕測試，希望能夠正確顯示。\n他們在說什麼？\n我不知道，但我們該走了。", CFStringEncodings.big5),
        ("简体中文字幕测试，希望能够正确显示。\n他们在说什么？\n我不知道，但我们该走了。", .GB_18030_2000),
        ("これは日本語の字幕テストです。\n彼らは何を言っているの？\n分からない、でも行こう。", .dosJapanese),
        ("이것은 한국어 자막 테스트입니다.\n그들이 무슨 말을 하고 있나요?\n모르겠어요, 하지만 가야 해요.", .EUC_KR),
    ])
    func decoderPicksTheEncodingThatMakesSense(text: String, encoding: CFStringEncodings) throws {
        let script = ASSFixture.script(text: text.replacingOccurrences(of: "\n", with: "\\N"))
        let expected = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(encoding.rawValue)
        ))
        let data = try #require(script.data(using: expected))
        #expect(ASSTextEncoding.decoded(data) == script)
    }

    /// Bytes that are not one of the four legacy scripts must fall through to
    /// libass' own iconv rather than being mangled into confident nonsense.
    @Test("undecodable bytes are left to libass")
    func unknownBytesAreNotForced() {
        #expect(ASSTextEncoding.decoded(Data([0xFF, 0xFE, 0x00, 0x01, 0x02, 0x03])) == nil)
    }

    /// One corrupt byte in a UTF-8 file is a damaged file, not a legacy one.
    /// Strict decoding rejects the whole script over it, and the legacy sniffer
    /// then reads a megabyte of UTF-8 as GB18030 — every glyph wrong, no
    /// diagnostic. A lossy decode is taken when the damage is a rounding error.
    @Test("a UTF-8 script with one bad byte is still UTF-8")
    func oneBadByteStaysUTF8() async throws {
        let script = ASSFixture.script(
            text: "简体中文字幕测试，希望能够正确显示。这是第二行的文字，够长以便识别。",
            fontName: "SimHei"
        )
        var bytes = Array(script.utf8)
        #expect(String(data: Data(bytes), encoding: .utf8) != nil)
        // A stray continuation byte in the middle of the header — invalid UTF-8
        // anywhere, and nowhere near the dialogue.
        bytes.insert(0xC3, at: bytes.firstIndex(of: UInt8(ascii: "[")) ?? 0)
        let damaged = Data(bytes)
        #expect(String(data: damaged, encoding: .utf8) == nil)

        let decoded = try #require(ASSTextEncoding.utf8(damaged))
        #expect(decoded.contains("简体中文字幕测试"))

        // …and through the real path the cue renders from the Chinese face,
        // not from whatever GB18030 would have made of UTF-8 bytes.
        let renderer = await makeProbeRenderer()
        try await renderer.load(damaged, format: .ass)
        _ = try #require(await renderer.frame(at: 2.0))
        #expect(selected("Noto Sans CJK SC", in: await renderer.diagnosticLog))
    }

    /// Bytes damaged beyond a rounding error are NOT UTF-8, and must go to the
    /// sniffer rather than being handed on full of replacement characters.
    @Test("a thoroughly broken decode is not accepted as UTF-8")
    func heavilyDamagedBytesAreNotUTF8() {
        #expect(ASSTextEncoding.utf8(Data(repeating: 0xC3, count: 64)) == nil)
    }

    /// Big5 text is almost entirely VALID GB18030 and vice versa, so the order
    /// of the candidates is load-bearing: narrowest first, GB18030 last, and
    /// the FIRST that reads as a language it serves wins. Scoring them all and
    /// taking the highest confidence compared numbers the recognizer never
    /// meant to be comparable.
    @Test("a GBK script decodes as GB18030 and a Big5 one as Big5")
    func narrowestQualifyingCandidateWins() throws {
        for (text, encoding, expected) in [
            (
                "简体中文字幕测试，希望能够正确显示。\n他们在说什么？\n我不知道，但我们该走了。",
                CFStringEncodings.GB_18030_2000, "简体中文字幕测试"
            ),
            (
                "繁體中文字幕測試，希望能夠正確顯示。\n他們在說什麼？\n我不知道，但我們該走了。",
                CFStringEncodings.big5, "繁體中文字幕測試"
            ),
        ] {
            let script = ASSFixture.script(
                text: text.replacingOccurrences(of: "\n", with: "\\N")
            )
            let data = try #require(script.data(using: String.Encoding(
                rawValue: CFStringConvertEncodingToNSStringEncoding(
                    CFStringEncoding(encoding.rawValue)
                )
            )))
            let decoded = try #require(ASSTextEncoding.decoded(data))
            #expect(decoded.contains(expected), "\(decoded.prefix(200))")
        }
    }
}
