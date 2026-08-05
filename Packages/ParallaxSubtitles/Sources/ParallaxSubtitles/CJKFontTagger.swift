import Foundation

/// Makes CJK font choice explicit in converted scripts.
///
/// libass resolves a glyph its current font lacks by asking the platform for a
/// fallback one codepoint at a time — with no language context, so the answer
/// tracks the device's preferred-languages list and can split a single Chinese
/// line across two fonts. Converted SRT/WebVTT text is ours to write, so
/// instead of repairing that lottery after the fact, every CJK run is wrapped
/// in an explicit `\fn` naming the family the track plan chose for that line's
/// language. libass then matches by family and never consults its fallback.
enum CJKFontTagger {

    /// One lexical unit of an escaped ASS Text field.
    enum Token: Equatable {
        /// A `{...}` override block, passed through verbatim.
        case override(String)
        /// A two-character backslash escape (`\\`, `\{`, `\h`, …), passed
        /// through verbatim; its rendered character is never CJK.
        case escaped(String)
        /// A literal character.
        case character(Character)
        /// `\N` or `\n` — the literal is preserved for reassembly.
        case lineBreak(String)
    }

    static func tokenize(_ text: String) -> [Token] {
        var tokens: [Token] = []
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if character == "{", let close = text[index...].firstIndex(of: "}") {
                tokens.append(.override(String(text[index...close])))
                index = text.index(after: close)
                continue
            }
            if character == "\\" {
                let nextIndex = text.index(after: index)
                if nextIndex < text.endIndex {
                    let next = text[nextIndex]
                    let pair = String([character, next])
                    tokens.append(next == "N" || next == "n" ? .lineBreak(pair) : .escaped(pair))
                    index = text.index(after: nextIndex)
                    continue
                }
            }
            tokens.append(.character(character))
            index = text.index(after: index)
        }
        return tokens
    }

    /// The visual lines of an ASS Text field as plain text: override blocks and
    /// escapes stripped, split at `\N`/`\n`. What language detection sees.
    static func plainLines(of text: String) -> [String] {
        var lines: [String] = []
        var current = ""
        for token in tokenize(text) {
            switch token {
            case .character(let character): current.append(character)
            case .lineBreak: lines.append(current); current = ""
            case .override, .escaped: break
            }
        }
        lines.append(current)
        return lines
    }

    /// Rewrites one event's Text field with `\fn` around every CJK run, chosen
    /// per visual line from the plan. Runs close with bare tags — libass
    /// reverts to the CURRENT style's values, which keeps the user's style
    /// override in charge of Latin text (a named reset would bake the load-time
    /// default in and silently defeat a Serif/Mono caption choice).
    ///
    /// - Parameter styleFontSize: the synthesized style's Fontsize, in script
    ///   units. CJK runs whose family declares a tall win box also get `\fs`
    ///   compensation so an em renders at this size instead of being divided by
    ///   the box — otherwise CJK sits visually smaller than the Latin around it
    ///   (and its outline proportionally heavier).
    static func tagged(_ text: String, plan: SystemGlyphFont.Plan, styleFontSize: Double) -> String {
        var out = ""
        var segment: [Token] = []

        func flush() {
            out += taggedSegment(segment, plan: plan, styleFontSize: styleFontSize)
            segment = []
        }

        for token in tokenize(text) {
            if case .lineBreak(let literal) = token {
                flush()
                out += literal
            } else {
                segment.append(token)
            }
        }
        flush()
        return out
    }

    private static func taggedSegment(
        _ tokens: [Token],
        plan: SystemGlyphFont.Plan,
        styleFontSize: Double
    ) -> String {
        let plain = String(tokens.compactMap {
            if case .character(let character) = $0 { return character } else { return nil }
        })
        guard let family = plan.family(forLine: plain) else { return reassembled(tokens) }

        // Relative to the STYLE font's box: the app-side scale mapping already
        // compensates the style font itself, so runs only need the difference.
        let factor = plan.sizeFactor(forFamily: family) / plan.styleFontEmBoxFactor
        let compensates = abs(factor - 1) > 0.02
        let size = String(format: "%.1f", styleFontSize * factor)
        let open = compensates
            ? "{\\fn\(tagSafe(family))\\fs\(size)}"
            : "{\\fn\(tagSafe(family))}"
        let close = compensates ? "{\\fn\\fs}" : "{\\fn}"
        var out = ""
        var inRun = false
        func endRun() {
            if inRun { out += close; inRun = false }
        }
        for token in tokens {
            switch token {
            case .character(let character) where isCJK(character):
                if !inRun { out += open; inRun = true }
                out.append(character)
            case .character(let character):
                endRun()
                out.append(character)
            case .escaped(let literal), .override(let literal), .lineBreak(let literal):
                endRun()
                out += literal
            }
        }
        endRun()
        return out
    }

    private static func reassembled(_ tokens: [Token]) -> String {
        tokens.reduce(into: "") { out, token in
            switch token {
            case .character(let character): out.append(character)
            case .override(let literal), .escaped(let literal), .lineBreak(let literal):
                out += literal
            }
        }
    }

    private static func isCJK(_ character: Character) -> Bool {
        character.unicodeScalars.first.map { SystemGlyphFont.isCJKScalar($0.value) } ?? false
    }

    /// A `\fn` argument runs to the next `\` or `}`; a family name carrying
    /// either would swallow the rest of the line.
    private static func tagSafe(_ family: String) -> String {
        String(family.filter { $0 != "\\" && $0 != "}" && $0 != "{" })
    }
}

/// Read-only scans over an authored ASS/SSA script — the inputs the font plan
/// and shadow registration need, without ever rewriting authored text.
enum ASSScriptScan {

    struct Result {
        /// Plain visual lines of every Dialogue event.
        var plainLines: [String] = []
        /// Font families requested by styles or inline `\fn` overrides that
        /// govern at least one CJK-bearing event. Latin-only styles stay out:
        /// shadowing them with CJK-only glyphs would hijack their text.
        var cjkFontNames: Set<String> = []
    }

    static func scan(script: String) -> Result {
        // Column layouts come from the section's own Format line; the defaults
        // match both V4 (SSA) and V4+ (ASS).
        var styleNameColumn = 0
        var styleFontColumn = 1
        var eventStyleColumn = 3
        var eventTextColumn = 9

        var fontByStyle: [String: String] = [:]
        var result = Result()
        var inStyles = false
        var inEvents = false

        for raw in script.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                let section = line.lowercased()
                inStyles = section.contains("styles")
                inEvents = section.contains("events")
            } else if line.hasPrefix("Format:") {
                let columns = line.dropFirst("Format:".count)
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                if inStyles {
                    styleNameColumn = columns.firstIndex(of: "name") ?? styleNameColumn
                    styleFontColumn = columns.firstIndex(of: "fontname") ?? styleFontColumn
                } else if inEvents {
                    eventStyleColumn = columns.firstIndex(of: "style") ?? eventStyleColumn
                    eventTextColumn = columns.firstIndex(of: "text") ?? eventTextColumn
                }
            } else if line.hasPrefix("Style:") {
                let fields = line.dropFirst("Style:".count)
                    .split(separator: ",", omittingEmptySubsequences: false)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                if fields.indices.contains(styleNameColumn),
                   fields.indices.contains(styleFontColumn) {
                    fontByStyle[fields[styleNameColumn]] = normalizedFontName(fields[styleFontColumn])
                }
            } else if line.hasPrefix("Dialogue:") {
                // Text is the LAST field by format; commas inside it are literal.
                let fields = line.dropFirst("Dialogue:".count)
                    .split(separator: ",", maxSplits: eventTextColumn, omittingEmptySubsequences: false)
                guard fields.count == eventTextColumn + 1 else { continue }
                let text = String(fields[eventTextColumn])
                let plainLines = CJKFontTagger.plainLines(of: text)
                result.plainLines.append(contentsOf: plainLines)

                let hasCJK = plainLines.contains {
                    $0.unicodeScalars.contains { SystemGlyphFont.isCJKScalar($0.value) }
                }
                guard hasCJK else { continue }
                if fields.indices.contains(eventStyleColumn) {
                    // `*Default` marks an SSA style carried over unchanged.
                    var styleName = fields[eventStyleColumn].trimmingCharacters(in: .whitespaces)
                    if styleName.hasPrefix("*") { styleName.removeFirst() }
                    if let font = fontByStyle[styleName] { result.cjkFontNames.insert(font) }
                }
                for name in inlineFontNames(in: text) {
                    let cleaned = normalizedFontName(name)
                    if !cleaned.isEmpty { result.cjkFontNames.insert(cleaned) }
                }
            }
        }
        result.cjkFontNames.remove("")
        return result
    }

    private static func inlineFontNames(in text: String) -> [String] {
        var names: [String] = []
        var search = text[...]
        while let range = search.range(of: "\\fn") {
            let argument = search[range.upperBound...].prefix { $0 != "\\" && $0 != "}" }
            names.append(String(argument))
            search = search[argument.endIndex...]
        }
        return names
    }

    /// Strips the `@` vertical-layout marker and whitespace — `@X` names the
    /// same face as `X`.
    private static func normalizedFontName(_ raw: String) -> String {
        var name = raw.trimmingCharacters(in: .whitespaces)
        if name.hasPrefix("@") { name.removeFirst() }
        return name
    }
}
