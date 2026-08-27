import Foundation
import NaturalLanguage

/// Recovers the text of a fansub script that predates UTF-8.
///
/// GBK/GB18030, Big5, Shift_JIS and EUC-KR files are still everywhere, and
/// handing their raw bytes to libass' own iconv path renders them — but past
/// our font machinery: the substitution pre-pass cannot parse them, so every
/// style collapses onto `default_family` and every line onto the bare (Japanese)
/// face. Decoding here puts them back on the normal path.
///
/// Sniffing is unavoidable and cannot be done on bytes alone: Big5 text is
/// almost entirely *valid* GB18030, so "the first encoding that decodes" would
/// silently pick mojibake (measured: 這是一段繁體… decodes as 硂琌琿羉砰… with no
/// replacement character in sight). What separates them is the RESULT — real
/// text scores as a language the encoding actually serves, mojibake does not,
/// and where both score the recognizer's confidence separates them. Candidates
/// are ordered narrowest-first so the near-universal GB18030 only wins when
/// nothing more specific claims the bytes.
enum ASSTextEncoding {

    struct Candidate {
        let encoding: String.Encoding
        /// The languages this encoding exists to carry. A decode whose text
        /// reads as anything else is mojibake by definition.
        let languages: Set<NLLanguage>
    }

    static let candidates: [Candidate] = [
        Candidate(encoding: encoding(.dosJapanese), languages: [.japanese]),
        Candidate(encoding: encoding(.EUC_KR), languages: [.korean]),
        Candidate(encoding: encoding(.big5), languages: [.traditionalChinese]),
        Candidate(
            encoding: encoding(.GB_18030_2000),
            languages: [.simplifiedChinese, .traditionalChinese]
        ),
    ]

    private static func encoding(_ cf: CFStringEncodings) -> String.Encoding {
        String.Encoding(
            rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(cf.rawValue))
        )
    }

    /// UTF-8 first, and forgivingly: one corrupt byte in a megabyte of UTF-8 is
    /// a damaged file, not a legacy one, and sending it to the sniffer would
    /// mangle the whole script into confident nonsense. A lossy decode is
    /// accepted when the replacement characters are a rounding error; anything
    /// more is left for `decoded`.
    static func utf8(_ data: Data) -> String? {
        if let strict = String(data: data, encoding: .utf8) { return strict }
        let lossy = String(decoding: data, as: UTF8.self)
        let scalars = lossy.unicodeScalars.count
        guard scalars > 0 else { return nil }
        // One damaged scalar is always a rounding error, whatever the length —
        // a short cue file has no room for a thousandth. A legacy-encoded
        // script fails this by two orders of magnitude: nearly every non-ASCII
        // byte comes back as U+FFFD.
        let damaged = lossy.unicodeScalars.count { $0 == "\u{FFFD}" }
        return damaged <= max(1, scalars / 1000) ? lossy : nil
    }

    /// The first candidate whose decode reads as a language it exists to carry,
    /// or nil when none does — in which case the bytes are not one of these
    /// scripts and libass should see them raw.
    ///
    /// FIRST-qualifying, not best-scoring: the candidates are ordered
    /// narrowest-first, and "narrowest that claims the bytes" is the whole rule.
    /// Comparing confidences across encodings compares numbers the recognizer
    /// never meant to be comparable, and it let the near-universal GB18030 take
    /// Big5 text whenever its mojibake happened to score higher.
    static func decoded(_ data: Data) -> String? {
        // Scored on a prefix: the recognizer settles long before a full track,
        // and four decodes of a multi-thousand-cue script would otherwise be
        // paid in full four times.
        let sample = data.prefix(scoringSampleBytes)
        for candidate in candidates {
            guard let scored = decode(sample, as: candidate.encoding),
                  let language = dominantLanguage(of: scored),
                  candidate.languages.contains(language),
                  // The sample may have been cut mid-character; the text handed
                  // on is always a decode of the whole file.
                  let full = String(data: data, encoding: candidate.encoding)
            else { continue }
            return full
        }
        return nil
    }

    /// Decodes `data` and rejects anything with a replacement character in it —
    /// the marker of bytes the encoding does not actually describe.
    ///
    /// Up to three trailing bytes are dropped before giving up: the scoring
    /// sample is cut at a byte count, which lands mid-character in a
    /// double-byte encoding roughly half the time, and that is a truncation
    /// artefact rather than evidence about the encoding.
    private static func decode(_ data: Data, as encoding: String.Encoding) -> String? {
        for dropped in 0..<4 {
            guard let text = String(data: data.dropLast(dropped), encoding: encoding) else {
                continue
            }
            if !text.contains("\u{FFFD}") { return text }
        }
        return nil
    }

    /// Scored on the DIALOGUE only: an ASS script's headers, timecodes and
    /// style rows are ASCII whatever the encoding, and they dilute a short
    /// track's evidence into noise.
    private static func dominantLanguage(of script: String) -> NLLanguage? {
        let dialogue = ASSScriptScan.scan(script: script).plainLines.joined(separator: "\n")
        let sample = dialogue.isEmpty ? script : dialogue
        guard !sample.isEmpty else { return nil }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(sample)
        return recognizer.languageHypotheses(withMaximum: 1)
            .max(by: { $0.value < $1.value })?
            .key
    }

    /// Enough bytes for the recognizer to settle on any real script.
    private static let scoringSampleBytes = 16_384
}
