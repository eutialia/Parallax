import Foundation
import NaturalLanguage

/// Decides which CJK language a track, and each of its lines, is written in.
///
/// The four CJK writing systems share code points but not shapes: 直 and 令 are
/// drawn differently in a Chinese and a Japanese face, and both faces cover
/// both. So the choice cannot be made per character — libass' own per-glyph
/// fallback has no language context at all, and even with one bundled family
/// per region a character-at-a-time answer would split one line across two
/// designs. This settles the track's default first, then classifies each visual
/// line; `SubtitleFontPlan` turns those answers into families.
///
/// Public only for its `Language`, which `SubtitleFontBundle.family` takes.
public enum CJKFontPlan {

    // MARK: - Scripts and scalar classes

    /// The CJK languages whose writing systems need distinct font choices.
    /// Raw values are BCP-47 tags.
    public enum Language: String, CaseIterable, Sendable {
        case japanese = "ja"
        case korean = "ko"
        case simplifiedChinese = "zh-Hans"
        case traditionalChinese = "zh-Hant"

        /// Maps a track's language label ("ja", "zh-Hant", "chi-TW", …) onto a
        /// member, comparing whole subtags (so "zh-Mong" cannot match "mo").
        /// Bare "zh" carries no script and maps to nothing — content detection
        /// decides instead.
        public init?(hintTag: String?) {
            guard let tag = hintTag?.lowercased(), !tag.isEmpty else { return nil }
            let subtags = tag.split { $0 == "-" || $0 == "_" }.map(String.init)
            guard let primary = subtags.first else { return nil }
            switch primary {
            case "ja", "jpn": self = .japanese
            case "ko", "kor": self = .korean
            case "zh", "chi", "zho", "cmn", "yue":
                let rest = subtags.dropFirst()
                if rest.contains(where: { ["hant", "tw", "hk", "mo"].contains($0) }) {
                    self = .traditionalChinese
                } else if rest.contains(where: { ["hans", "cn", "sg"].contains($0) }) {
                    self = .simplifiedChinese
                } else {
                    return nil
                }
            default: return nil
            }
        }

        var isChinese: Bool { self == .simplifiedChinese || self == .traditionalChinese }
    }

    /// Scalars that belong to a CJK font's design: ideographs, kana, hangul
    /// syllables, CJK punctuation/radicals, compatibility and full/half-width
    /// forms. Deliberately NOT "everything ≥ U+2E80": emoji, symbols and
    /// private-use scalars are not part of a regional face's repertoire and
    /// must not drag a run onto one.
    static func isCJKScalar(_ value: UInt32) -> Bool {
        switch value {
        case 0x1100...0x11FF,       // hangul jamo
             0x2E80...0x9FFF,       // radicals … punctuation, kana, unified + ext A
             0xA960...0xA97F,       // hangul jamo extended-A
             0xAC00...0xD7FF,       // hangul syllables + jamo extended-B
             0xF900...0xFAFF,       // compatibility ideographs
             0xFE30...0xFE4F,       // vertical/compat forms
             0xFF00...0xFFEF,       // full-width and half-width forms
             0x20000...0x3FFFF:     // ext B+ and compatibility supplement
            return true
        default:
            return false
        }
    }

    /// Kana that DECIDES a line is Japanese. Excludes the interpunct (・), the
    /// prolonged-sound mark (ー), `゠` and their half-width forms — Chinese
    /// subtitles use them in transliterated names, and one must not flip a
    /// whole line to a Japanese face.
    private static func isDecisiveKana(_ value: UInt32) -> Bool {
        switch value {
        case 0x3041...0x309F, 0x30A1...0x30FA, 0x30FD...0x30FF,
             0x31F0...0x31FF, 0xFF66...0xFF6F, 0xFF71...0xFF9D:
            return true
        default:
            return false
        }
    }

    private static func isHangul(_ value: UInt32) -> Bool {
        switch value {
        case 0x1100...0x11FF, 0x3130...0x318F, 0xAC00...0xD7A3: return true
        default: return false
        }
    }

    private static func isHan(_ value: UInt32) -> Bool {
        switch value {
        case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0x20000...0x3FFFF: return true
        default: return false
        }
    }

    // MARK: - Language decisions

    /// The script assumed for lines that carry no decisive evidence of their
    /// own. The track's label wins outright — a Japanese track's kanji-only
    /// lines must NOT be second-guessed (the recognizer only knows the two
    /// Chinese classes, so it scores 東京駅 as high-confidence zh-Hant).
    /// Without a label: meaningful kana/hangul presence claims the track, and
    /// otherwise the Han-only lines vote Hans vs Hant.
    static func trackDefaultLanguage(lines: [String], hint: String?) -> Language {
        if let hinted = Language(hintTag: hint) { return hinted }

        var kanaLines = 0
        var hangulLines = 0
        var hanOnlyLines: [String] = []
        for line in lines {
            var sawHan = false
            var decided = false
            scan: for scalar in line.unicodeScalars {
                if isDecisiveKana(scalar.value) { kanaLines += 1; decided = true; break scan }
                if isHangul(scalar.value) { hangulLines += 1; decided = true; break scan }
                if isHan(scalar.value) { sawHan = true }
            }
            if !decided, sawHan { hanOnlyLines.append(line) }
        }
        // ≥20% decisive lines is a real second language, not a stray lyric. A
        // dual-language track lands on ONE default and stays there: with every
        // regional face carrying the full Han repertoire there is no coverage
        // signal left to detect the other language's rows from, so a zh row in
        // a ja-defaulted track renders with Japanese Han shapes unless its own
        // characters are decisive.
        if kanaLines > 0, kanaLines * 4 >= hanOnlyLines.count { return .japanese }
        if hangulLines > 0, hangulLines * 4 >= hanOnlyLines.count { return .korean }

        var hans = 0
        var hant = 0
        // One recognizer, reset per line: a fresh NLLanguageRecognizer costs
        // ~9x a reset (measured), and this loop runs up to the vote sample
        // limit's worth of lines.
        let recognizer = NLLanguageRecognizer()
        for line in hanOnlyLines.prefix(chineseVoteSampleLimit) {
            switch chineseScript(of: line, using: recognizer) {
            case .simplifiedChinese: hans += 1
            case .traditionalChinese: hant += 1
            default: break
            }
        }
        if hans != hant { return hans > hant ? .simplifiedChinese : .traditionalChinese }
        return chineseScript(
            of: hanOnlyLines.prefix(chineseVoteSampleLimit).joined(separator: "\n"), using: recognizer
        ) ?? .simplifiedChinese
    }

    /// Whole-track voting caps here — enough for any real ambiguity, and it
    /// keeps recognizer cost bounded on multi-thousand-cue tracks.
    private static let chineseVoteSampleLimit = 400

    /// The language governing font choice for one visual line, or nil when the
    /// line has no CJK content at all. Kana and hangul decide outright; Han is
    /// discriminated Hans/Hant only inside a Chinese-defaulted track; anything
    /// else (shared characters, CJK punctuation alone) takes the track default.
    static func language(
        of line: String, trackDefault: Language, using recognizer: NLLanguageRecognizer = NLLanguageRecognizer()
    ) -> Language? {
        var sawCJK = false
        var sawHan = false
        for scalar in line.unicodeScalars {
            if isDecisiveKana(scalar.value) { return .japanese }
            if isHangul(scalar.value) { return .korean }
            if isHan(scalar.value) {
                sawCJK = true
                sawHan = true
            } else if isCJKScalar(scalar.value) {
                sawCJK = true
            }
        }
        guard sawCJK else { return nil }
        if sawHan, trackDefault.isChinese, let script = chineseScript(of: line, using: recognizer) { return script }
        return trackDefault
    }

    /// zh-Hans vs zh-Hant for Han text, or nil when the characters don't tip
    /// the scales either way. Only meaningful for text already known to be
    /// Chinese: the recognizer is constrained to the two Chinese classes and
    /// renormalizes over them, so it is confidently wrong about Japanese kanji.
    static func chineseScript(
        of text: String, using recognizer: NLLanguageRecognizer = NLLanguageRecognizer()
    ) -> Language? {
        // reset() drops the constraints along with the accumulated evidence, so
        // a caller reusing one recognizer across lines must reapply them here.
        recognizer.reset()
        recognizer.languageConstraints = [.simplifiedChinese, .traditionalChinese]
        recognizer.processString(text)
        guard let best = recognizer.languageHypotheses(withMaximum: 2)
            .max(by: { ($0.value, $1.key.rawValue) < ($1.value, $0.key.rawValue) }),
            best.value >= 0.65 else { return nil }
        switch best.key {
        case .simplifiedChinese: return .simplifiedChinese
        case .traditionalChinese: return .traditionalChinese
        default: return nil
        }
    }
}
