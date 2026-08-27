import Foundation

/// Translates an authored ASS/SSA script's font names onto the bundled Noto
/// faces.
///
/// We do not have the fansub's fonts and never will, so their names cannot be
/// *matched* — with every system provider off, a `Style:` naming `Arial` or
/// `MS Mincho` resolves to nothing. Rather than let all of them collapse onto
/// one `default_family`, the author's name is read for the one property that
/// survives substitution — whether it wanted a serif — and routed to Noto Serif
/// or Noto Sans (or the track's CJK region face). Colours, sizes, positions and
/// every other field are left exactly as authored.
///
/// Two things are rewritten, both font names and nothing else:
/// 1. the `Fontname` field of each `Style:` line;
/// 2. the argument of each inline `\fn` override.
///
/// A third, narrower rewrite adds the faces a substituted style cannot draw:
/// every non-Latin, non-CJK script run is wrapped in `{\fn<script face>}` + a
/// bare reset, and so is a CJK run on a line whose language differs from the
/// track default. CJK lines that agree with the default are left alone — their
/// style already names the right face, so a tag there would be a change to
/// someone else's document with no effect on screen.
enum AuthoredFontSubstitution {

    // MARK: - Serif intent

    /// Names carrying any of these anywhere are sans, whatever else they say.
    /// `sans` first and unconditionally: "MS Sans Serif" is not a serif face,
    /// and it is the family a naive substring test gets wrong most often.
    private static let sansMarkers = [
        "sans", "gothic", "ゴシック", "黑", "黒", "고딕", "돋움", "굴림",
    ]

    /// Sans markers too short to be safe as substrings — `hei` would claim
    /// "Fahrenheit". Matched against whole tokens of the camel-split name, so
    /// "Microsoft YaHei" and "FZLanTingHei" hit and nothing else does.
    private static let sansTokens: Set<String> = ["hei", "heiti", "gothic"]

    /// Serif markers long enough to be unambiguous anywhere in the name. The
    /// CJK ones stay substrings by nature: 宋体, 細明體 and ＭＳ明朝 have no word
    /// boundaries to tokenise on.
    private static let serifMarkers = [
        "serif", "mincho", "simsun", "songti", "myeongjo",
        "明朝", "宋", "明", "바탕",
    ]

    /// Serif markers that are ordinary English fragments, matched on whole
    /// tokens only: "song" must not claim "Songbird", and "ming" must not claim
    /// "Flaming Text".
    private static let serifTokens: Set<String> = [
        "song", "ming", "times", "georgia", "garamond", "roman", "batang",
    ]

    static func design(forAuthoredName name: String) -> SubtitleFontBundle.Design {
        let lowered = name.lowercased()
        if sansMarkers.contains(where: lowered.contains) { return .sans }
        let tokens = tokens(of: name)
        if !tokens.isDisjoint(with: sansTokens) { return .sans }
        if serifMarkers.contains(where: lowered.contains) { return .serif }
        return tokens.isDisjoint(with: serifTokens) ? .sans : .serif
    }

    /// The words of a font name, lowercased. Splits on anything that is not a
    /// letter or digit AND on camel-case boundaries, because foundry prefixes
    /// are glued straight onto the design word in practice: `STSong` → st|song,
    /// `PMingLiU` → p|ming|li|u, `FZLanTingHei` → fz|lan|ting|hei.
    static func tokens(of name: String) -> Set<String> {
        let characters = Array(name)
        var tokens: Set<String> = []
        var current = ""

        func flush() {
            if !current.isEmpty { tokens.insert(current.lowercased()) }
            current = ""
        }

        for (index, character) in characters.enumerated() {
            guard character.isLetter || character.isNumber else {
                flush()
                continue
            }
            if character.isUppercase, let previous = characters[..<index].last {
                // A capital after a lowercase always starts a word; a capital in
                // a run of capitals only does when a lowercase follows it, which
                // is what separates the prefix in `MSMincho` from the `U` in
                // `PMingLiU`.
                let followedByLower = characters[characters.index(after: index)...].first?.isLowercase == true
                if !previous.isUppercase || followedByLower { flush() }
            }
            current.append(character)
        }
        flush()
        return tokens
    }

    // MARK: - Rewriting

    /// - Parameters:
    ///   - plan: the track's routing. Its default CJK language picks the face a
    ///     CJK-bearing style lands on — the Latin face when the track has none.
    ///   - scan: the read-only pass over the same script — its
    ///     `cjkBearingStyles` is what keeps a Latin-only style Latin. Passed in
    ///     by the renderer, which already made it for the plan; made here when
    ///     the caller has none.
    static func applied(
        to script: String, plan: SubtitleFontPlan, scan: ASSScriptScan.Result? = nil
    ) -> String {
        let scan = scan ?? ASSScriptScan.scan(script: script)
        var columns = ASSScriptScan.Columns()
        var familyByStyle: [String: String] = [:]
        var inStyles = false
        var inEvents = false

        // Rejoining with "\n" reproduces the original: CRLF scripts keep their
        // \r, blank lines keep their place.
        var lines = ASSScriptScan.lines(of: script)
        for index in lines.indices {
            // A CRLF script's \r belongs to the LINE, not to its last field —
            // carried into the Text field it would miss the plan's per-line
            // cache (keyed on trimmed lines) and re-run language detection on
            // every cue. Split off once here, re-attached after the rewrite.
            let (content, terminator) = ASSScriptScan.withoutLineTerminator(lines[index])
            let line = content.trimmingCharacters(in: .whitespacesAndNewlines)
            var rewritten: String?

            if line.hasPrefix("[") {
                let section = line.lowercased()
                inStyles = section.contains("styles")
                inEvents = section.contains("events")
            } else if line.hasPrefix("Format:") {
                columns.resolve(formatLine: line, inStyles: inStyles, inEvents: inEvents)
            } else if line.hasPrefix("Style:") {
                rewritten = substitutedStyle(
                    content, plan: plan, columns: columns,
                    cjkBearingStyles: scan.cjkBearingStyles,
                    familyByStyle: &familyByStyle
                )
            } else if line.hasPrefix("Dialogue:") {
                rewritten = substitutedDialogue(
                    content, plan: plan, columns: columns, familyByStyle: familyByStyle
                )
            }

            if let rewritten { lines[index] = rewritten + terminator }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Style lines

    /// The substituted family is the track's CJK region face only for a style
    /// that governs at least one CJK-bearing Dialogue. Anything else keeps the
    /// Latin face of its own serif intent: a `Style: Eng,Open Sans,…` used by
    /// nothing but English lines has no CJK to draw, and moving it onto a CJK
    /// face would render every one of those lines in that face's Latin design.
    private static func substitutedStyle(
        _ line: String,
        plan: SubtitleFontPlan,
        columns: ASSScriptScan.Columns,
        cjkBearingStyles: Set<String>,
        familyByStyle: inout [String: String]
    ) -> String {
        var (prefix, fields) = ASSScriptScan.splitASSFields(line)
        guard fields.indices.contains(columns.styleFont) else { return line }

        let authored = ASSScriptScan.normalizedFontName(fields[columns.styleFont])
        let design = design(forAuthoredName: authored)
        let name = fields.indices.contains(columns.styleName)
            ? ASSScriptScan.normalizedStyleName(fields[columns.styleName])
            : nil
        let language = name.map(cjkBearingStyles.contains) == true
            ? plan.trackDefaultLanguage
            : nil

        let family = SubtitleFontBundle.family(design: design, language: language)
        if let name { familyByStyle[name] = family }
        fields[columns.styleFont] = family
        return ASSScriptScan.joinASSFields(prefix: prefix, fields: fields)
    }

    // MARK: - Dialogue lines

    private static func substitutedDialogue(
        _ line: String,
        plan: SubtitleFontPlan,
        columns: ASSScriptScan.Columns,
        familyByStyle: [String: String]
    ) -> String {
        var (prefix, fields) = ASSScriptScan.splitASSFields(line, maxSplits: columns.eventText)
        guard fields.count == columns.eventText + 1 else { return line }

        // The face this event's own style resolved to — what decides whether a
        // run needs a tag at all, and which symbols the style can already draw.
        var styleFamily = SubtitleFontBundle.family(design: .sans, language: nil)
        if fields.indices.contains(columns.eventStyle),
           let resolved = familyByStyle[
               ASSScriptScan.normalizedStyleName(fields[columns.eventStyle])
           ] {
            styleFamily = resolved
        }

        // Inline names first: the script pass must not re-map its own tags.
        let named = substitutedInlineNames(in: fields[columns.eventText], plan: plan)
        fields[columns.eventText] = SubtitleFontTagger.authoredTagged(
            named,
            plan: plan.with(
                design: SubtitleFontBundle.design(forFamily: styleFamily),
                styleFamily: styleFamily
            )
        )
        return ASSScriptScan.joinASSFields(prefix: prefix, fields: fields)
    }

    /// Rewrites every `\fn<name>` argument. A bare `\fn` (the reset back to the
    /// style's font) carries no name and is left bare.
    private static func substitutedInlineNames(in text: String, plan: SubtitleFontPlan) -> String {
        var out = ""
        var rest = text[...]
        while let marker = rest.range(of: "\\fn") {
            out += rest[..<marker.upperBound]
            let argument = rest[marker.upperBound...].prefix { $0 != "\\" && $0 != "}" }
            rest = rest[argument.endIndex...]
            let authored = ASSScriptScan.normalizedFontName(String(argument))
            guard !authored.isEmpty else { continue }
            out += SubtitleFontBundle.family(
                design: design(forAuthoredName: authored), language: plan.trackDefaultLanguage
            )
        }
        return out + rest
    }
}
