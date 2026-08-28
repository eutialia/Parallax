import Foundation

/// Text handling shared by the SRT and WebVTT converters: timestamp parsing,
/// inline tag mapping, ASS escaping and HTML entity decoding.
enum CueMarkup {

    // MARK: - Source normalisation

    /// Strips a UTF-8 BOM and folds CRLF/CR endings to LF, so every later step
    /// can assume plain LF-separated lines.
    static func normalized(_ text: String) -> String {
        var text = text
        if text.hasPrefix("\u{FEFF}") {
            text.removeFirst()
        }
        return text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }

    // MARK: - Timestamps

    /// Parses `[HH:]MM:SS[.,]mmm` into seconds. Both formats in scope allow a
    /// comma or a period as the decimal mark in the wild, and WebVTT legitimately
    /// omits the hours field.
    static func seconds(fromTimestamp raw: some StringProtocol) -> Double? {
        let text = raw.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }

        let colonParts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard colonParts.count == 2 || colonParts.count == 3 else { return nil }

        var seconds = 0.0
        for part in colonParts.dropLast() {
            guard let value = Int(part), value >= 0 else { return nil }
            seconds = seconds * 60 + Double(value)
        }
        seconds *= 60

        let last = colonParts[colonParts.count - 1].replacingOccurrences(of: ",", with: ".")
        let secondsParts = last.split(separator: ".", omittingEmptySubsequences: false)
        guard let whole = Int(secondsParts[0]), whole >= 0 else { return nil }
        seconds += Double(whole)

        if secondsParts.count > 1 {
            let fraction = secondsParts[1]
            guard !fraction.isEmpty, fraction.allSatisfy(\.isNumber), let value = Int(fraction) else {
                return nil
            }
            seconds += Double(value) / pow(10, Double(fraction.count))
        }

        // ASS timecodes top out at H:MM:SS.cc with no field width limit on H, but
        // Double->Int conversion downstream traps past a few hundred years' worth
        // of seconds. 100 hours is already an absurd cue time; reject rather than
        // let a malformed timestamp propagate.
        guard seconds.isFinite, seconds <= 359_999.99 else { return nil }
        return seconds
    }

    /// Splits a `start --> end [settings]` line. Returns nil unless both sides parse.
    static func timing(fromLine line: some StringProtocol) -> (start: Double, end: Double, settings: String)? {
        guard let arrow = line.range(of: "-->") else { return nil }
        guard let start = seconds(fromTimestamp: line[line.startIndex..<arrow.lowerBound]) else { return nil }

        let tail = line[arrow.upperBound...].trimmingCharacters(in: .whitespaces)
        // The end timestamp runs to the first space; anything after it is cue settings.
        let endToken = tail.prefix(while: { !$0.isWhitespace })
        guard let end = seconds(fromTimestamp: endToken) else { return nil }

        let settings = tail.dropFirst(endToken.count).trimmingCharacters(in: .whitespaces)
        return (start, end, settings)
    }

    // MARK: - Inline markup

    /// A piece of converted cue text.
    enum Token: Equatable {
        /// Raw source text, not yet escaped.
        case text(String)
        /// A finished ASS override block such as `{\i1}`, inserted verbatim.
        case override(String)
    }

    /// Options that differ between the two source formats.
    struct MarkupOptions {
        /// Decode `&amp;` and friends. WebVTT is HTML-ish and requires it; SRT
        /// carries literal characters.
        var decodesEntities: Bool
    }

    /// Turns one cue body into tokens.
    ///
    /// Angle-bracket tags become ASS overrides (`<i>`, `<b>`, `<u>`) or are
    /// dropped (`<font>`, `<c>`, `<v Speaker>`, ruby, WebVTT timestamps).
    /// Literal `{\an8}` / `{\a6}` blocks survive untouched: placing an SRT line
    /// at the top of the screen that way is a widespread convention, and libass
    /// honours it once the text reaches it intact.
    static func tokenize(_ body: String, options: MarkupOptions) -> [Token] {
        var tokens: [Token] = []
        var pending = ""

        func flushText() {
            if !pending.isEmpty {
                tokens.append(.text(pending))
                pending = ""
            }
        }

        var index = body.startIndex
        while index < body.endIndex {
            let character = body[index]

            if character == "{", let block = alignmentOverride(in: body, from: index) {
                flushText()
                tokens.append(.override(block.text))
                index = block.end
                continue
            }

            if character == "<", let close = body[index...].firstIndex(of: ">") {
                let inner = String(body[body.index(after: index)..<close])
                if let mapped = assOverride(forHTMLTag: inner) {
                    flushText()
                    tokens.append(.override(mapped))
                }
                // Unmapped tags (font, c, v, ruby, timestamps) are simply dropped.
                index = body.index(after: close)
                continue
            }

            pending.append(character)
            index = body.index(after: index)
        }
        flushText()

        guard options.decodesEntities else { return tokens }
        return tokens.map { token in
            if case .text(let value) = token { return .text(decodeEntities(value)) }
            return token
        }
    }

    /// Renders tokens into the Text field of a Dialogue line.
    static func assText(_ tokens: [Token]) -> String {
        tokens.reduce(into: "") { result, token in
            switch token {
            case .text(let value): result += escape(value)
            case .override(let value): result += value
            }
        }
    }

    /// Makes raw cue text safe to drop into a Dialogue Text field.
    ///
    /// libass gives meaning to exactly five sequences in event text — `\N`,
    /// `\n`, `\h`, `\{` and `\}` — and has NO escape for the backslash itself:
    /// any other `\x` is a literal backslash followed by `x`, so doubling one
    /// draws two. A source backslash is therefore emitted once and followed by
    /// a WORD JOINER, which is zero-width, non-breaking and default-ignorable:
    /// it draws nothing and it guarantees the author's next character cannot
    /// complete an escape (`C:\New`, `\{`, `\h`).
    ///
    /// `{` still has to be escaped — unescaped it opens an override block and
    /// swallows the rest of the line — and a hard newline becomes `\N`.
    static func escape(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        for character in text {
            switch character {
            case "\\": out += "\\\u{2060}"
            case "{": out += "\\{"
            case "}": out += "\\}"
            case "\n": out += "\\N"
            default: out.append(character)
            }
        }
        return out
    }

    // MARK: - Entities

    private static let namedEntities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'",
        "nbsp": "\u{00A0}", "lrm": "\u{200E}", "rlm": "\u{200F}",
    ]

    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var out = ""
        var index = text.startIndex

        while index < text.endIndex {
            guard text[index] == "&",
                  let semicolon = text[index...].prefix(12).firstIndex(of: ";") else {
                out.append(text[index])
                index = text.index(after: index)
                continue
            }

            let body = String(text[text.index(after: index)..<semicolon])
            if let replacement = replacement(forEntityBody: body) {
                out += replacement
                index = text.index(after: semicolon)
            } else {
                out.append(text[index])
                index = text.index(after: index)
            }
        }
        return out
    }

    private static func replacement(forEntityBody body: String) -> String? {
        if let named = namedEntities[body.lowercased()] { return named }
        guard body.hasPrefix("#") else { return nil }

        let digits = body.dropFirst()
        let value: UInt32?
        if digits.first == "x" || digits.first == "X" {
            value = UInt32(digits.dropFirst(), radix: 16)
        } else {
            value = UInt32(digits, radix: 10)
        }
        return value.flatMap { UnicodeScalar($0) }.map { String(Character($0)) }
    }

    // MARK: - Tag tables

    private static func assOverride(forHTMLTag inner: String) -> String? {
        let name = inner.trimmingCharacters(in: .whitespaces).lowercased()
        switch name {
        case "i": return "{\\i1}"
        case "/i": return "{\\i0}"
        case "b": return "{\\b1}"
        case "/b": return "{\\b0}"
        case "u": return "{\\u1}"
        case "/u": return "{\\u0}"
        default: return nil
        }
    }

    /// Matches `{\an8}` or `{\a6}` starting at `start`, and nothing else.
    private static func alignmentOverride(
        in body: String,
        from start: String.Index
    ) -> (text: String, end: String.Index)? {
        var index = body.index(after: start)
        guard index < body.endIndex, body[index] == "\\" else { return nil }
        index = body.index(after: index)
        guard index < body.endIndex, body[index] == "a" else { return nil }
        index = body.index(after: index)

        if index < body.endIndex, body[index] == "n" {
            index = body.index(after: index)
        }

        var digits = 0
        while index < body.endIndex, body[index].isNumber, digits < 2 {
            index = body.index(after: index)
            digits += 1
        }
        guard digits > 0, index < body.endIndex, body[index] == "}" else { return nil }

        let end = body.index(after: index)
        return (String(body[start..<end]), end)
    }
}
