import Foundation

/// Makes font choice explicit, per run, in every script we hand libass.
///
/// No bundled file covers every writing system and `ASS_FONTPROVIDER_NONE`
/// leaves libass nothing to fall back to, so a run that names no family it can
/// place renders as tofu. And within CJK, every regional face covers the whole
/// Han repertoire, so libass would happily draw a Chinese line from the
/// Japanese face — same code points, wrong shapes, no diagnostic.
///
/// Both are solved the same way: `SubtitleScript` segments each visual line
/// into runs, `SubtitleFontPlan` names the family for each, and the run is
/// wrapped in `{\fn<family>}…{\fn}`. Runs that resolve to the style's own
/// family are left alone.
enum SubtitleFontTagger {

    /// One lexical unit of an escaped ASS Text field.
    enum Token: Equatable {
        /// A `{...}` override block, passed through verbatim.
        case override(String)
        /// A two-character backslash escape (`\\`, `\{`, `\h`, …), passed
        /// through verbatim; its rendered character carries no script.
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

    /// Rewrites one event's Text field with `\fn` around every run whose script
    /// needs a face the style does not name — converted scripts, whose text is
    /// ours to write. Runs close with bare tags: libass then reverts to the
    /// CURRENT style's values, which keeps the user's style override in charge
    /// (a named reset would bake the load-time default in and silently defeat a
    /// Serif/Sans caption choice).
    ///
    /// - Parameter styleFontSize: the synthesized style's Fontsize, in script
    ///   units. A run whose family declares a taller win box than the style font
    ///   also gets `\fs` compensation so its em renders at this size instead of
    ///   being divided by the box — otherwise it sits visually smaller than the
    ///   Latin around it (and its outline proportionally heavier). The bundled
    ///   boxes span 1.24 (Noto Sans Tamil) to 2.50 (Noto Serif Myanmar), so
    ///   without this a Myanmar caption renders at 61% of a Latin one.
    static func tagged(_ text: String, plan: SubtitleFontPlan, styleFontSize: Double) -> String {
        rewritten(text, routing: plan.symbolRouting, closesWith: .styleFont) { line, runClass in
            guard let family = plan.family(forRun: runClass, line: line, scope: .allRuns) else {
                return nil
            }
            // Relative to the STYLE font's box: the app-side scale mapping
            // already compensates the style font itself, so runs only need the
            // difference.
            let factor = plan.sizeFactor(forFamily: family) / plan.styleFontEmBoxFactor
            guard abs(factor - 1) > 0.02 else { return Tags(family: family) }
            return Tags(family: family, size: styleFontSize * factor)
        }
    }

    /// The authored-script rule: name the face for every run whose script the
    /// substituted style cannot draw, but leave CJK alone on lines that agree
    /// with the track default — those already render from the face their style
    /// names, and a tag there would be a change with no effect. Sizes are never
    /// touched: they belong to the author.
    /// Sizes are never touched: they belong to the author. Neither is the
    /// author's own `\fn` — a tagged run closes by restoring whatever font was
    /// in force where it started (`Closer.authorFont`).
    static func authoredTagged(_ text: String, plan: SubtitleFontPlan) -> String {
        rewritten(text, routing: plan.symbolRouting, closesWith: .authorFont) { line, runClass in
            plan.family(forRun: runClass, line: line, scope: .divergentLines)
                .map { Tags(family: $0) }
        }
    }

    /// What a tagged run reverts to when it ends.
    private enum Closer {
        /// A bare `{\fn}`: libass reverts to the CURRENT style's font, which
        /// keeps the user's style override in charge. Right for converted
        /// scripts, whose text carries no author `\fn` to preserve.
        case styleFont
        /// The font the author had in force at that point — a bare reset there
        /// would silently discard their own `\fn` for the rest of the line.
        case authorFont
    }

    /// The `{...}` pair wrapping one run.
    private struct Tags {
        let family: String
        var size: Double? = nil

        var open: String {
            let sizeTag = size.map { "\\fs" + String(format: "%.1f", $0) } ?? ""
            return "{\\fn\(SubtitleFontTagger.tagSafe(family))\(sizeTag)}"
        }

        /// - Parameter restoring: the author's in-force family, or nil for the
        ///   style's own font.
        func close(restoring family: String?) -> String {
            let name = family.map(SubtitleFontTagger.tagSafe) ?? ""
            return size == nil ? "{\\fn\(name)}" : "{\\fn\(name)\\fs}"
        }
    }

    /// Splits the field at line breaks and wraps each visual line's runs.
    ///
    /// The author's in-force `\fn` is tracked across the WHOLE field, not per
    /// visual line: `\N` is a line break, not a reset, so an override before one
    /// still governs the text after it.
    private static func rewritten(
        _ text: String,
        routing: SubtitleScript.SymbolRouting,
        closesWith closer: Closer,
        tags: (String, SubtitleScript.Class) -> Tags?
    ) -> String {
        var out = ""
        var segment: [Token] = []
        var authorFont: String?

        func flush() {
            out += taggedSegment(
                segment, routing: routing, closer: closer, authorFont: &authorFont, tags: tags
            )
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

    /// The `\fn` argument an override block leaves in force, or nil when it
    /// resets to the style's font. Blocks with no `\fn` leave `current` alone.
    ///
    /// The last one wins: `{\fnA\fnB}` is B, and libass reads the block the same
    /// way.
    static func inForceFont(after block: String, current: String?) -> String? {
        var result = current
        var rest = block[...]
        while let marker = rest.range(of: "\\fn") {
            let argument = rest[marker.upperBound...].prefix { $0 != "\\" && $0 != "}" }
            rest = rest[argument.endIndex...]
            let name = ASSScriptScan.normalizedFontName(String(argument))
            result = name.isEmpty ? nil : name
        }
        return result
    }

    /// Groups one visual line's characters into script runs and tags each.
    ///
    /// A character with no class of its own — a combining mark or a ZWJ/ZWNJ —
    /// stays in the run in force, which is what keeps a Devanagari conjunct and
    /// its joiner in one font. Everything else, punctuation included, has a
    /// class and decides for itself.
    ///
    /// Override blocks, escapes and line breaks close the current run: they may
    /// carry the author's own `\fn`, and a wrapper spanning one would fight it.
    private static func taggedSegment(
        _ tokens: [Token],
        routing: SubtitleScript.SymbolRouting,
        closer: Closer,
        authorFont: inout String?,
        tags: (String, SubtitleScript.Class) -> Tags?
    ) -> String {
        let plain = String(tokens.compactMap {
            if case .character(let character) = $0 { return character } else { return nil }
        })

        var out = ""
        var openTags: Tags?
        var runClass: SubtitleScript.Class = .common
        let inForce = { (font: String?) in closer == .authorFont ? font : nil }

        func close(restoring font: String?) {
            if let openTags { out += openTags.close(restoring: inForce(font)) }
            openTags = nil
        }

        for token in tokens {
            switch token {
            case .character(let character):
                let resolved = SubtitleScript.classify(character, routing: routing) ?? runClass
                if resolved != runClass {
                    close(restoring: authorFont)
                    runClass = resolved
                }
                if openTags == nil, let wanted = tags(plain, runClass) {
                    out += wanted.open
                    openTags = wanted
                }
                out.append(character)
            case .escaped(let literal), .override(let literal), .lineBreak(let literal):
                close(restoring: authorFont)
                if case .override = token {
                    authorFont = inForceFont(after: literal, current: authorFont)
                }
                // The next character re-decides; a run cannot span a block.
                runClass = .common
                out += literal
            }
        }
        close(restoring: authorFont)
        return out
    }

    private static func tagSafe(_ family: String) -> String {
        String(family.filter { $0 != "\\" && $0 != "}" && $0 != "{" })
    }
}

/// Read-only scan over an authored ASS/SSA script: the plain dialogue text the
/// font plan classifies. Rewriting authored scripts is
/// `AuthoredFontSubstitution`'s job, not this one's.
enum ASSScriptScan {

    struct Result {
        /// Plain visual lines of every Dialogue event.
        var plainLines: [String] = []
        /// Names of the styles governing at least one CJK-bearing Dialogue.
        ///
        /// What keeps a Latin-only style on a Latin face in a CJK track: a
        /// `Style: Eng,Open Sans,…` used by nothing but Latin lines has no
        /// reason to become the region's CJK face, and making it one renders
        /// every English caption in the CJK face's Latin design.
        var cjkBearingStyles: Set<String> = []
    }

    /// Where each field a rewrite touches sits, resolved from the `Format:`
    /// lines of the two sections that have them. The defaults are V4 (SSA) and
    /// V4+ (ASS), which agree on all four.
    struct Columns {
        var styleName = 0
        var styleFont = 1
        var eventStyle = 3
        var eventText = 9

        /// - Parameters:
        ///   - inStyles: the `Format:` belongs to a `[… Styles]` section.
        ///   - inEvents: … to `[Events]`.
        mutating func resolve(formatLine: String, inStyles: Bool, inEvents: Bool) {
            let columns = formatColumns(of: formatLine)
            if inStyles {
                styleName = columns.firstIndex(of: "name") ?? styleName
                styleFont = columns.firstIndex(of: "fontname") ?? styleFont
            } else if inEvents {
                eventStyle = columns.firstIndex(of: "style") ?? eventStyle
                eventText = columns.firstIndex(of: "text") ?? eventText
            }
        }
    }

    /// `Dialogue: 0,…,text` → (`"Dialogue"`, the comma-separated fields).
    ///
    /// - Parameter maxSplits: the Text field is LAST by format and its commas
    ///   are literal, so event lines cap the split at its column.
    static func splitASSFields(
        _ line: String, maxSplits: Int = .max
    ) -> (prefix: String, fields: [String]) {
        let prefix = line.prefix { $0 != ":" }
        let fields = line.dropFirst(prefix.count + 1)
            .split(separator: ",", maxSplits: maxSplits, omittingEmptySubsequences: false)
            .map(String.init)
        return (String(prefix), fields)
    }

    static func joinASSFields(prefix: String, fields: [String]) -> String {
        prefix + ":" + fields.joined(separator: ",")
    }

    /// The script's lines, split at LF only.
    ///
    /// `script.split(separator: "\n")` cannot do this: Swift treats CRLF as a
    /// single Character, so a CRLF-authored script — most of them — comes back
    /// as one enormous line. Splitting the scalar view sees the LF, and
    /// rejoining the pieces with "\n" reproduces the original bytes exactly.
    static func lines(of script: String) -> [String] {
        script.unicodeScalars
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { String(String.UnicodeScalarView($0)) }
    }

    /// Splits a trailing CR off a line so its last field is keyed the same way
    /// whether the script is CRLF or LF. Everything downstream compares against
    /// trimmed text; a stray \r rides into the Text field otherwise.
    static func withoutLineTerminator(_ line: String) -> (content: String, terminator: String) {
        line.hasSuffix("\r") ? (String(line.dropLast()), "\r") : (line, "")
    }

    /// The lowercased column names of a `Format:` line, in order — the mapping
    /// every ASS section's fields are read through.
    static func formatColumns(of line: String) -> [String] {
        line.dropFirst("Format:".count)
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
    }

    static func scan(script: String) -> Result {
        var columns = Columns()
        var inStyles = false
        var inEvents = false
        var result = Result()

        for raw in lines(of: script) {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("[") {
                let section = line.lowercased()
                inStyles = section.contains("styles")
                inEvents = section.contains("events")
            } else if line.hasPrefix("Format:") {
                columns.resolve(formatLine: line, inStyles: inStyles, inEvents: inEvents)
            } else if line.hasPrefix("Dialogue:") {
                let (_, fields) = splitASSFields(line, maxSplits: columns.eventText)
                guard fields.count == columns.eventText + 1 else { continue }
                let plain = SubtitleFontTagger.plainLines(of: fields[columns.eventText])
                result.plainLines.append(contentsOf: plain)
                guard fields.indices.contains(columns.eventStyle),
                      plain.contains(where: {
                          $0.unicodeScalars.contains { CJKFontPlan.isCJKScalar($0.value) }
                      })
                else { continue }
                result.cjkBearingStyles.insert(normalizedStyleName(fields[columns.eventStyle]))
            }
        }
        return result
    }

    /// Every family a finished script will ask libass for: the `Fontname` of
    /// each `Style:` row and the argument of every inline `\fn`.
    ///
    /// This is read off the script we are about to hand libass, AFTER
    /// substitution and tagging, so it is exactly the set `fontselect` will look
    /// for — which is what makes it safe to register only those files.
    static func requestedFamilies(in script: String) -> Set<String> {
        var columns = Columns()
        var inStyles = false
        var inEvents = false
        var families: Set<String> = []

        for raw in lines(of: script) {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("[") {
                let section = line.lowercased()
                inStyles = section.contains("styles")
                inEvents = section.contains("events")
            } else if line.hasPrefix("Format:") {
                columns.resolve(formatLine: line, inStyles: inStyles, inEvents: inEvents)
            } else if line.hasPrefix("Style:") {
                let (_, fields) = splitASSFields(line)
                guard fields.indices.contains(columns.styleFont) else { continue }
                families.insert(normalizedFontName(fields[columns.styleFont]))
            }
        }

        var rest = script[...]
        while let marker = rest.range(of: "\\fn") {
            let argument = rest[marker.upperBound...].prefix { $0 != "\\" && $0 != "}" }
            rest = rest[argument.endIndex...]
            families.insert(normalizedFontName(String(argument)))
        }
        families.remove("")
        return families
    }

    /// Strips the `@` vertical-layout marker and whitespace — `@X` names the
    /// same face as `X`. No real family name approaches 128 characters, so a
    /// longer one is treated as hostile input and dropped.
    static func normalizedFontName(_ raw: String) -> String {
        var name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.hasPrefix("@") { name.removeFirst() }
        guard name.count <= 128 else { return "" }
        return name
    }

    /// A style reference as written in a `Style:` name field or a `Dialogue:`
    /// style field. The leading `*` marks a style the renderer synthesized and
    /// is not part of the name the two sides match on.
    static func normalizedStyleName(_ raw: String) -> String {
        var name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.hasPrefix("*") { name.removeFirst() }
        return name
    }
}
