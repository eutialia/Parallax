import Foundation
import NaturalLanguage

/// A track's font routing: which bundled family serves each run of each line.
///
/// Built once per loaded track, before libass sees the script. Two decisions
/// live here and they have different shapes:
///
/// - **Script** is per RUN and decided by the characters (`SubtitleScript`).
///   Thai is Thai; nothing else can make it Latin.
/// - **CJK region** is per LINE and decided by language. The four CJK writing
///   systems share code points but not shapes, and every regional face covers
///   the whole Han repertoire, so a character-at-a-time answer is impossible in
///   principle — 直 is drawn differently in a Chinese and a Japanese face and
///   both faces have it.
struct SubtitleFontPlan {

    /// Which lines a plan is allowed to tag for CJK.
    enum Scope {
        /// Every run gets an explicit family — converted scripts, whose text is
        /// ours to write.
        case allRuns
        /// CJK runs are tagged only on lines whose language differs from the
        /// track default; those lines' own style already names the right face,
        /// and an injected tag there is a change to someone else's document
        /// with no effect on screen. Non-CJK scripts are ALWAYS tagged — the
        /// substituted style names a Latin or CJK face, which has no Thai.
        case divergentLines
    }

    /// The design the style font belongs to; a `with(design:)` copy re-routes
    /// the same line assignment onto the other design.
    var design: SubtitleFontBundle.Design
    /// The family the style names. A run resolving to it needs no tag.
    ///
    /// Per-STYLE for authored scripts: `with(design:styleFamily:)` re-points it
    /// at whatever the substitution wrote into that `Style:` row, so both "this
    /// run needs no tag" and symbol coverage are asked of the face the line will
    /// really render from.
    var styleFamily: String
    /// The style font's own em box — the reference per-run `\fs` compensation
    /// is relative to (the app-side scale mapping already accounts for it).
    let styleFontEmBoxFactor: Double
    /// The track's CJK language, or nil when it has no CJK at all.
    let trackDefaultLanguage: CJKFontPlan.Language?
    /// Per-line CJK classification computed once at plan time — detection runs
    /// a recognizer, and tagging revisits every line. A stored nil is an answer
    /// ("no CJK here"), and telling it apart from "never seen" is what makes a
    /// cache miss detectable.
    let languageByLine: [String: CJKFontPlan.Language?]
    /// Test-supplied em-box factors, keyed by family. Empty in production: the
    /// real numbers are read from the shipped files.
    let sizeFactorByFamily: [String: Double]
    /// Shared with every `with(design:)` copy — they classify the same lines.
    let cacheMisses = CacheMisses()

    init(
        design: SubtitleFontBundle.Design,
        styleFamily: String,
        styleFontEmBoxFactor: Double,
        trackDefaultLanguage: CJKFontPlan.Language?,
        languageByLine: [String: CJKFontPlan.Language?],
        sizeFactorByFamily: [String: Double] = [:]
    ) {
        self.design = design
        self.styleFamily = styleFamily
        self.styleFontEmBoxFactor = styleFontEmBoxFactor
        self.trackDefaultLanguage = trackDefaultLanguage
        self.languageByLine = languageByLine
        self.sizeFactorByFamily = sizeFactorByFamily
    }

    /// Counts classifications that missed the per-line cache.
    ///
    /// Every visual line of a loaded track was classified at plan time, so a
    /// miss means the lookup key drifted from the plan's key — which costs a
    /// fresh `NLLanguageRecognizer` per cue and, worse, is invisible in the
    /// output. A CRLF script's stray `\r` did exactly that; this is what the
    /// regression test asserts on.
    final class CacheMisses: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0

        var value: Int {
            lock.lock()
            defer { lock.unlock() }
            return count
        }

        func increment() {
            lock.lock()
            defer { lock.unlock() }
            count += 1
        }
    }

    // MARK: - Routing

    /// The family a run of `runClass` on `line` must be tagged with, or nil when
    /// it already renders from the style font.
    func family(forRun runClass: SubtitleScript.Class, line: String, scope: Scope = .allRuns) -> String? {
        let family: String
        switch runClass {
        case .common:
            return nil
        case .symbol(let routed):
            family = routed
        case .script(let script):
            family = SubtitleFontBundle.family(design: design, script: script)
        case .cjk:
            guard let language = language(ofLine: line) else { return nil }
            if scope == .divergentLines, language == trackDefaultLanguage { return nil }
            family = SubtitleFontBundle.family(design: design, script: .cjk(language))
        }
        return family == styleFamily ? nil : family
    }

    /// The CJK language governing `line`, from the plan's cache.
    func language(ofLine line: String) -> CJKFontPlan.Language? {
        let cached = languageByLine[Self.cacheKey(line)]
        if cached == nil { cacheMisses.increment() }
        return cached ?? CJKFontPlan.language(
            of: line, trackDefault: trackDefaultLanguage ?? .japanese
        )
    }

    /// The one normalisation of a visual line into a cache key.
    ///
    /// Both sides have to agree exactly or every cue re-runs language detection
    /// invisibly: the scan trims each script line before splitting its fields,
    /// so its Text field has lost any trailing whitespace the rewrite's field
    /// still carries. Trimming in one place is what makes them meet.
    static func cacheKey(_ line: String) -> String {
        line.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Where a symbol the style face cannot draw is routed. Depends on the
    /// style family, so every `with(...)` copy gets its own.
    var symbolRouting: SubtitleScript.SymbolRouting {
        SubtitleScript.SymbolRouting(
            styleFamily: styleFamily,
            candidates: SubtitleFontBundle.symbolFallbackOrder(
                design: design, language: trackDefaultLanguage
            )
        )
    }

    /// The em box libass divides a requested size by for `family`. Read from
    /// the shipped file unless a test supplied one.
    func sizeFactor(forFamily family: String) -> Double {
        sizeFactorByFamily[family] ?? SubtitleFontMetrics.emBoxFactor(forFamily: family)
    }

    /// The same assignment against another design and style face — how an
    /// authored script's serif styles keep their design while still landing on
    /// the right script, and how a Latin-only style keeps its Latin face.
    func with(
        design: SubtitleFontBundle.Design, styleFamily: String? = nil
    ) -> SubtitleFontPlan {
        var copy = self
        copy.design = design
        if let styleFamily { copy.styleFamily = styleFamily }
        return copy
    }

    // MARK: - Building

    /// Builds the routing plan for a track's visual lines.
    ///
    /// Always succeeds: with an all-Noto bundle every script needs routing, not
    /// just CJK, so there is no "nothing to do" answer. The CJK half is skipped
    /// entirely when the track has none, which is the common case and costs one
    /// scalar scan.
    static func build(lines: [String], styleFamily: String, languageHint: String?) -> SubtitleFontPlan {
        let design = SubtitleFontBundle.design(forFamily: styleFamily)
        let styleFactor = SubtitleFontMetrics.emBoxFactor(forFamily: styleFamily)

        let hasCJK = lines.contains { $0.unicodeScalars.contains { CJKFontPlan.isCJKScalar($0.value) } }
        guard hasCJK else {
            return SubtitleFontPlan(
                design: design, styleFamily: styleFamily,
                styleFontEmBoxFactor: styleFactor,
                trackDefaultLanguage: nil, languageByLine: [:]
            )
        }

        let trackDefault = CJKFontPlan.trackDefaultLanguage(lines: lines, hint: languageHint)

        // One recognizer for every line this plan classifies — a fresh
        // NLLanguageRecognizer per line measured ~9x a reset, ~0.7s on a
        // 3000-line Chinese-default track.
        let recognizer = NLLanguageRecognizer()
        var languageByLine: [String: CJKFontPlan.Language?] = [:]
        for line in lines.map(cacheKey) where languageByLine.index(forKey: line) == nil {
            languageByLine[line] = CJKFontPlan.language(
                of: line, trackDefault: trackDefault, using: recognizer
            )
        }

        return SubtitleFontPlan(
            design: design, styleFamily: styleFamily,
            styleFontEmBoxFactor: styleFactor,
            trackDefaultLanguage: trackDefault, languageByLine: languageByLine
        )
    }
}
