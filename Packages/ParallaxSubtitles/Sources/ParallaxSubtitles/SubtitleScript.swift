import Foundation

/// Classifies text by writing system, so every run of a cue can be routed to a
/// face that actually carries its glyphs.
///
/// With `ASS_FONTPROVIDER_NONE` and no single file covering every script, a run
/// libass cannot place has nowhere to fall back to — it draws nothing, or logs
/// `Using default font family` and draws tofu. So the choice is never left to
/// libass: the text is segmented here and each run is named explicitly.
enum SubtitleScript {

    /// What a scalar contributes to run segmentation. Three cases because the
    /// three route differently, not for tidiness.
    enum Class: Hashable, Sendable {
        /// Latin, Greek, Cyrillic, and any letter no bundled face claims — the
        /// style font's own bucket. Never tagged.
        case common
        /// CJK. WHICH regional face serves it is a per-LINE decision the font
        /// plan makes from the line's language, not a per-scalar one: the four
        /// writing systems share code points but not shapes.
        case cjk
        /// A script with one bundled face per design; the scalar decides it
        /// outright.
        case script(SubtitleFontBundle.Script)
        /// A symbol the style face has no glyph for, routed by COVERAGE to a
        /// bundled family that does. Carries the family so consecutive symbols
        /// answering to the same face stay one run.
        case symbol(family: String)
    }

    /// Where a symbol goes when the style face cannot draw it.
    ///
    /// ♪ ♫ ♥ ★ → ● ▶ ∞ are ordinary in subtitles and absent from
    /// `NotoSans/NotoSerif-Regular`; the pan-CJK collections carry nearly all of
    /// them. With `ASS_FONTPROVIDER_NONE` there is no per-glyph fallback to save
    /// an unrouted one — it renders `.notdef` — so the answer is read out of the
    /// files' own `cmap`s instead of from a block table nobody can keep current.
    ///
    /// Letters are NOT routed this way: which face draws a script is a
    /// script-identity question the block table answers, and letting coverage
    /// decide would smuggle a Latin letter the style face happens to miss into a
    /// CJK face's Latin design.
    ///
    /// **Emoji stay unsupported.** No bundled Noto file carries them, so a
    /// coverage search finds nothing and they render as the style face's
    /// `.notdef`. Fixing that means shipping an emoji font, not routing.
    struct SymbolRouting: Equatable {
        /// The family the run would otherwise render from — asked first, so text
        /// the style face can draw is never moved off it.
        let styleFamily: String
        /// Fallbacks in preference order (`SubtitleFontBundle.symbolFallbackOrder`).
        let candidates: [String]

        static let none = SymbolRouting(styleFamily: "", candidates: [])

        /// The family to draw `scalar` with, or nil when the style face already
        /// covers it (or nothing does).
        func family(for scalar: Unicode.Scalar) -> String? {
            guard !candidates.isEmpty,
                  !SubtitleFontBundle.covers(scalar.value, family: styleFamily)
            else { return nil }
            return candidates.first { SubtitleFontBundle.covers(scalar.value, family: $0) }
        }
    }

    /// The class of `scalar`, or nil when it belongs to whichever run it sits in.
    ///
    /// Nil is reserved for the two categories that CANNOT be split off their
    /// neighbours without changing what is drawn:
    ///
    /// - **Combining marks** (Mn/Mc/Me) belong to their base by definition — a
    ///   Thai vowel sign or a Devanagari matra in a different font from its
    ///   consonant is a broken cluster, not a font choice.
    /// - **Format characters** (Cf) are ZWJ and ZWNJ, which is how Indic
    ///   conjuncts are asked for and suppressed. Split off the run, they stop
    ///   reaching HarfBuzz's shaper for it.
    ///
    /// Ordinary punctuation, spaces, digits and symbols are `.common` and
    /// therefore render from the Latin face, which has by far the widest
    /// coverage of them. That deliberately cuts `مرحبا بالعالم` into two Arabic
    /// runs at the space and it costs nothing: Arabic letters are non-joining
    /// across a space anyway, and bidi is computed over the whole line, not per
    /// font run. Full-width CJK punctuation is not affected — it is inside the
    /// CJK blocks and claimed before this point.
    static func classify(
        _ scalar: Unicode.Scalar, routing: SymbolRouting = .none
    ) -> Class? {
        switch scalar.properties.generalCategory {
        case .nonspacingMark, .spacingMark, .enclosingMark, .format: return nil
        default: break
        }
        let value = scalar.value
        if CJKFontPlan.isCJKScalar(value) { return .cjk }
        if let script = bundledScript(value) { return .script(script) }
        // ASCII is in every bundled face; skipping it keeps the common path free
        // of coverage lookups entirely.
        if value > 0x7F, isRoutableSymbol(scalar), let family = routing.family(for: scalar) {
            return .symbol(family: family)
        }
        return .common
    }

    /// The class of a `Character`, decided by its first scalar — the base of a
    /// grapheme cluster, which is what the marks after it inherit from.
    static func classify(_ character: Character, routing: SymbolRouting = .none) -> Class? {
        character.unicodeScalars.first.flatMap { classify($0, routing: routing) }
    }

    /// Symbols and punctuation — the categories whose glyph is the same whoever
    /// draws it, so borrowing a face for one changes nothing but whether it
    /// appears. Letters, digits, marks and separators are deliberately excluded.
    private static func isRoutableSymbol(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .mathSymbol, .currencySymbol, .modifierSymbol, .otherSymbol,
             .dashPunctuation, .openPunctuation, .closePunctuation,
             .initialPunctuation, .finalPunctuation, .connectorPunctuation,
             .otherPunctuation:
            return true
        default:
            return false
        }
    }

    // MARK: - Block table

    /// Unicode blocks of the scripts the bundle carries a dedicated face for,
    /// sorted by lower bound and searched by bisection — this runs per scalar of
    /// every cue of every track.
    ///
    /// CJK is absent on purpose: `CJKFontPlan.isCJKScalar` already owns that
    /// answer, and it deliberately excludes emoji and symbols that share the
    /// high blocks.
    private static let blocks: [(range: ClosedRange<UInt32>, script: SubtitleFontBundle.Script)] = [
        (0x0530...0x058F, .armenian),
        (0x0590...0x05FF, .hebrew),
        (0x0600...0x06FF, .arabic),
        (0x0750...0x077F, .arabic),   // Arabic Supplement
        (0x0870...0x089F, .arabic),   // Arabic Extended-B
        (0x08A0...0x08FF, .arabic),   // Arabic Extended-A
        (0x0900...0x097F, .devanagari),
        (0x0980...0x09FF, .bengali),
        (0x0A00...0x0A7F, .gurmukhi),
        (0x0A80...0x0AFF, .gujarati),
        (0x0B00...0x0B7F, .oriya),
        (0x0B80...0x0BFF, .tamil),
        (0x0C00...0x0C7F, .telugu),
        (0x0C80...0x0CFF, .kannada),
        (0x0D00...0x0D7F, .malayalam),
        (0x0D80...0x0DFF, .sinhala),
        (0x0E00...0x0E7F, .thai),
        (0x0E80...0x0EFF, .lao),
        (0x1000...0x109F, .myanmar),
        (0x10A0...0x10FF, .georgian),
        (0x1780...0x17FF, .khmer),
        (0x19E0...0x19FF, .khmer),    // Khmer Symbols
        (0x1C90...0x1CBF, .georgian), // Georgian Extended (Mtavruli)
        (0x2D00...0x2D2F, .georgian), // Georgian Supplement (Nuskhuri)
        (0xA8E0...0xA8FF, .devanagari), // Devanagari Extended
        (0xA9E0...0xA9FF, .myanmar),  // Myanmar Extended-B
        (0xAA60...0xAA7F, .myanmar),  // Myanmar Extended-A
        (0xFB13...0xFB17, .armenian), // Armenian ligatures
        (0xFB1D...0xFB4F, .hebrew),   // Hebrew presentation forms
        (0xFB50...0xFDFF, .arabic),   // Arabic presentation forms A
        (0xFE70...0xFEFF, .arabic),   // Arabic presentation forms B
    ]

    private static func bundledScript(_ value: UInt32) -> SubtitleFontBundle.Script? {
        var low = 0
        var high = blocks.count - 1
        while low <= high {
            let middle = (low + high) / 2
            let block = blocks[middle]
            if value < block.range.lowerBound {
                high = middle - 1
            } else if value > block.range.upperBound {
                low = middle + 1
            } else {
                return block.script
            }
        }
        return nil
    }
}
