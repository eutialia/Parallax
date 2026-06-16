import Foundation

/// Transport-agnostic sidecar-subtitle filename matching.
///
/// Pure value logic — no I/O, no SMB types — so it is unit-testable in isolation and reusable for
/// any sidecar-subtitle source (SMB today, local files later). `SMBSubtitleResolver` owns the
/// listing/URL side and delegates every name decision here.
///
/// ## Why this exists
/// The old rule only matched a sibling whose stem was byte-identical to the video stem, optionally
/// followed by `.tokens`. That misses the common real case where the subtitle is from a *different
/// release* than the video (different group, dropped/added quality tags, episode-only naming). This
/// matcher loosens to tolerate that drift **while refusing to cross-attach the wrong episode** —
/// the episode/season/year/part numbers are hard gates, not fuzzy inputs.
///
/// ## Tier order (first hit wins; better labels first)
/// - **T1** exact stem → `"Default"`
/// - **T2** `videoStem + "." + suffix` → `suffix` verbatim (preserves `en`, `en.forced`, `jptc`)
/// - **T3** same episode+season, drifted tags → recovered language / differing group / `epNN`
/// - **T4** no episode either side, same title (+ same year if both carry one) → language / `Default`
/// - **T5** exactly one video in the folder → attach any subtitle sibling → language / `Default`
///
/// ## Hard rejects (block T3/T4; suspended at T5 since one video can't cross-attach)
/// episode conflict, season conflict, year conflict, multi-part conflict, one-sided episode in a
/// multi-video folder, special-content mismatch (OP/ED/NCED/sample/…), sequel differentiator
/// (`Movie 2` vs `Movie`), disjoint title.
enum SubtitleMatcher {

    // MARK: - Vocabulary

    /// Tokens that carry no identity — stripped from the title core and never used as a label.
    private static let noiseTokens: Set<String> = [
        // resolution
        "2160p", "1080p", "720p", "480p", "360p", "4k", "uhd", "hd", "sd",
        // codec / profile
        "x264", "x265", "h264", "h265", "hevc", "avc", "xvid", "divx",
        "10bit", "8bit", "ma10p", "hi10p", "hi444",
        // audio
        "aac", "ac3", "eac3", "ddp", "dd", "dts", "truehd", "atmos", "flac", "opus", "mp3", "2ch", "6ch",
        // source / medium
        "bluray", "bdrip", "brrip", "bd", "webrip", "webdl", "web", "hdtv", "dvd", "dvdrip",
        "remux", "hdr", "hdr10", "dv", "sdr", "repack", "proper", "dl",
        "baha", "bilibili", "cr", "crunchyroll", "funimation", "amzn", "nf", "dsnp", "vrv",
        // pack / junk
        "multiple", "subtitle", "subtitles", "subs",
    ]

    /// Language codes recognised for labels. Combo codes (`jptc`, `sc_jp`→`sc.jp`) are handled by
    /// separator splitting before lookup, so only atomic codes live here.
    private static let languageTokens: Set<String> = [
        "en", "eng", "english",
        "ja", "jp", "jpn", "japanese",
        "chs", "sc", "gb", "gbsc", "zh",
        "cht", "tc", "big5",
        "ko", "kor", "korean",
        "fr", "fra", "fre",
        "es", "spa",
        "de", "ger", "deu",
        "it", "ita",
        "pt", "por",
        "ru", "rus",
        "ar", "ara",
        "nl", "nld", "dut",
    ]

    /// Subtitle qualifier flags appended after the language in a label. `hi`/`full` are deliberately
    /// omitted — too collision-prone with ordinary title words.
    private static let subtitleFlagTokens: Set<String> = [
        "forced", "sdh", "cc", "signs", "songs", "commentary", "comm",
    ]

    /// Special-content markers (whole-token). A mismatch between video and sub means they are
    /// different content (an opening vs an episode, a sample vs the feature) → reject.
    private static let specialContentTokens: Set<String> = [
        "op", "ed", "nced", "ncop", "sp", "oad", "ova", "ona", "menu", "pv", "cm",
        "preview", "trailer", "sample", "extra", "extras", "bonus", "creditless", "clean",
    ]

    /// Roman-numeral sequel markers. `i`/`x` are excluded — "i" collides with the pronoun and "x"
    /// with the common "A x B" title connector; arabic sequels are matched numerically, not listed.
    private static let romanSequelTokens: Set<String> = ["ii", "iii", "iv", "v", "vi", "vii", "viii", "ix", "xi", "xii", "xiii"]

    // MARK: - Compiled patterns (lowercased input, so patterns need no case flag)
    //
    // `Regex` is conservatively non-Sendable, but these bindings are immutable and matching is a
    // non-mutating, read-only operation — sharing one compiled instance across concurrent matches is
    // safe, so `nonisolated(unsafe)` is accurate (not a silenced race on mutable state).

    // NOTE: `.wordBoundaryKind(.simple)` is mandatory on every `\b` pattern. Swift Regex defaults to
    // UAX#29 boundaries, where a "." between digit runs ("2021.1080") is a numeric separator — so
    // there is NO `\b` after "2021", and the year/episode/part match silently fails. `.simple` uses
    // the traditional \w↔\W boundary, which is what these scene-name patterns expect.
    nonisolated(unsafe) private static let seasonEpRegex = try! Regex(#"s(\d{1,2})e(\d{1,3})(?:-?e?(\d{1,3}))?"#)
    // Boundaries so a "1920x1080" resolution isn't read as season 20 / episode 108. Swift Regex has
    // no lookbehind, so the left edge consumes a start/non-digit-non-x char instead.
    nonisolated(unsafe) private static let seasonXRegex  = try! Regex(#"(?:^|[^\dx])(\d{1,2})x(\d{2,3})(?!\d)"#)
    // The episode keyword must start at a token boundary, else "movie1" reads its trailing "e1".
    nonisolated(unsafe) private static let explicitEpRegex = try! Regex(#"(?:^|[ ._\-\[\(])(?:episode|ep|e)[ ._]?(\d{1,4})\b"#).wordBoundaryKind(.simple)
    // Optional trailing `-NN` captures a multi-episode batch range (" - 12-13 "); group 2 is the span end.
    nonisolated(unsafe) private static let dashEpRegex   = try! Regex(#"(?:^|[ \]\)])-[ ]?(\d{1,4})(?:v\d+)?(?:-(\d{1,4}))?(?=$|[ \[\(._])"#)
    nonisolated(unsafe) private static let yearRegex     = try! Regex(#"\b(19\d{2}|20\d{2})\b"#).wordBoundaryKind(.simple)
    nonisolated(unsafe) private static let partRegex     = try! Regex(#"\b(?:cd|pt|part|disc|disk)[ ._]?(\d{1,2})\b"#).wordBoundaryKind(.simple)
    nonisolated(unsafe) private static let bracketRegex  = try! Regex(#"[\[\(\{]([^\]\)\}]*)[\]\)\}]"#)

    /// Characters that delimit tokens once bracket groups are flattened.
    private static let separators = CharacterSet(charactersIn: " ._-+&[](){}")

    // MARK: - Parsed filename

    /// Everything the tiers/guards need about one filename, computed once.
    struct NameModel: Sendable, Equatable {
        /// Lowercased, NFC, full-width-bracket-normalised, final-extension stripped.
        let stem: String
        /// Identity tokens after stripping brackets, episode/season/year markers, and noise. Single
        /// characters are kept — a sequel "2" or a "Show A"/"Show B" differentiator must survive.
        let titleTokens: Set<String>
        let episode: Int?
        /// End of a multi-episode span (`S01E01-E03`). Equals `episode` for a single episode.
        let episodeEnd: Int?
        let season: Int?
        let year: Int?
        let part: Int?
        let specialFlags: Set<String>
        /// Recovered language(+flag) label, e.g. `jptc`, `en.forced`, `sc.jp`. Lowercased.
        let language: String?
        /// Leading `[...]` group — the release group; used only to distinguish drifted-release subs.
        let groupTag: String?

        init(filename: String) {
            // N1/N2 — stem: drop the final extension, lowercase, NFC, normalise full-width brackets.
            var s = (filename as NSString).deletingPathExtension
                .precomposedStringWithCanonicalMapping
                .lowercased()
            for (fw, ascii) in [("［", "["), ("］", "]"), ("（", "("), ("）", ")")] {
                s = s.replacingOccurrences(of: fw, with: ascii)
            }
            self.stem = s

            // Bracket inner tokens (group tag, CRC, quality, episode) + the leading group.
            let bracketInners = s.matches(of: SubtitleMatcher.bracketRegex).compactMap {
                $0.output[1].substring.map(String.init)
            }
            self.groupTag = s.first == "[" ? bracketInners.first.flatMap { $0.isEmpty ? nil : $0 } : nil

            // N3 — year first, so episode extraction can reject a year-shaped number. Bound to a
            // local so the token-filter closure below doesn't capture a half-initialized `self`.
            let year = SubtitleMatcher.firstInt(SubtitleMatcher.yearRegex, in: s, group: 1)
            self.year = year

            let ep = SubtitleMatcher.extractEpisode(stem: s, bracketInners: bracketInners, year: year)
            // (a..e) failed → try (f): an episode-only name whose title reduces to a lone integer.

            // N6 — title core. Strip bracket groups, then the non-bracket episode/season/year MARKERS
            // by their regex match RANGE. A substring replace would shred a title digit-run that merely
            // contains the marker — "apollo 13" with episode "3" must keep "13", not collapse to "1".
            let titleRegion = s
                .replacing(SubtitleMatcher.bracketRegex, with: " ")
                .replacing(SubtitleMatcher.seasonEpRegex, with: " ")
                .replacing(SubtitleMatcher.seasonXRegex, with: " ")
                .replacing(SubtitleMatcher.dashEpRegex, with: " ")
                .replacing(SubtitleMatcher.explicitEpRegex, with: " ")
                .replacing(SubtitleMatcher.yearRegex, with: " ")
            let rawTokens = titleRegion
                .components(separatedBy: SubtitleMatcher.separators)
                .filter { !$0.isEmpty }

            // Identity tokens = non-noise, non-language words. Single characters are KEPT: a sequel
            // marker ("2") and a show differentiator ("A"/"B") are single chars that must survive to
            // distinguish "Movie 2" from "Movie" and "Show A" from "Show B". Only the episode/year
            // numbers themselves are dropped (they are not part of the title).
            var episode = ep.episode
            var episodeEnd = ep.end
            var identityTokens = rawTokens.filter {
                !SubtitleMatcher.noiseTokens.contains($0)
                && !SubtitleMatcher.isLanguageToken($0)
                && !($0.allSatisfy(\.isNumber) && (Int($0) == episode || Int($0) == year))
            }
            // (f) bare-integer episode: only when the title reduces to a single integer ("05.jpsc"
            // → ep 5), never when a real title word remains ("apollo 13" stays a title). `identityTokens`
            // is already the non-noise/non-language set; a year-shaped lone token is rejected below.
            if episode == nil {
                if identityTokens.count == 1, let only = identityTokens.first,
                   only.allSatisfy(\.isNumber), let n = Int(only), !(1900...2099).contains(n) {
                    episode = n
                    episodeEnd = n
                    identityTokens = []
                }
            }
            self.episode = episode
            self.episodeEnd = episodeEnd
            self.season = ep.season
            self.titleTokens = Set(identityTokens)

            // N4 — special-content flags (whole-token, scanned over the flattened stem).
            let allTokens = s.components(separatedBy: SubtitleMatcher.separators).filter { !$0.isEmpty }
            self.specialFlags = Set(allTokens.filter { SubtitleMatcher.specialContentTokens.contains($0) })

            // N5 — multi-part.
            self.part = SubtitleMatcher.firstInt(SubtitleMatcher.partRegex, in: s, group: 1)

            // N7 — language label: recognised language tokens (in source order) then flags, dot-joined.
            var langs: [String] = []
            var flags: [String] = []
            for token in allTokens {
                if SubtitleMatcher.languageTokens.contains(token) || SubtitleMatcher.combinationLanguage(token) != nil {
                    if !langs.contains(token) { langs.append(token) }
                } else if SubtitleMatcher.subtitleFlagTokens.contains(token), !flags.contains(token) {
                    flags.append(token)
                }
            }
            let combined = langs + flags  // combos (jptc/jpsc/big5gb) are kept verbatim
            self.language = combined.isEmpty ? nil : combined.joined(separator: ".")
        }
    }

    // MARK: - Match entry point

    /// Returns the label to attach `sub` under, or `nil` if it does not belong to `video`.
    ///
    /// - Parameter lonelyVideo: `true` when the directory holds exactly one video file. Enables the
    ///   T5 fallback and suspends the cross-attach guards (one video can't be cross-attached).
    static func label(forSub sub: NameModel, video: NameModel, lonelyVideo: Bool) -> String? {
        // T1 — exact stem.
        if sub.stem == video.stem { return "Default" }

        // T2 — videoStem + "." + suffix (byte-identical base ⇒ no guards needed).
        let dotted = video.stem + "."
        if sub.stem.hasPrefix(dotted) {
            let suffix = String(sub.stem.dropFirst(dotted.count))
            if !suffix.isEmpty { return suffix }
            // Trailing-dot-only ("Movie..srt"): malformed sidecar. Attach only in a lonely folder.
            return lonelyVideo ? (sub.language ?? "Default") : nil
        }

        // T5 — lonely video: attach anything (cross-attach is structurally impossible).
        if lonelyVideo { return sub.language ?? "Default" }

        // ---- Multi-video folder: loose tiers behind the hard-reject guards. ----

        // G1/G2/G3/G6 — number conflicts.
        if let ve = video.episode, let se = sub.episode, (ve, video.episodeEnd) != (se, sub.episodeEnd) { return nil }
        if let vs = video.season, let ss = sub.season, vs != ss { return nil }
        if let vy = video.year, let sy = sub.year, vy != sy { return nil }
        if let vp = video.part, let sp = sub.part, vp != sp { return nil }

        // G4/G6 — one-sided anchor in a multi-video folder is ambiguous across siblings.
        if (video.episode == nil) != (sub.episode == nil) { return nil }
        if (video.part == nil) != (sub.part == nil) { return nil }

        // G5 — special-content mismatch (NCED/OP/sample vs a normal episode).
        if video.specialFlags != sub.specialFlags { return nil }

        // G7 — sequel differentiator ("Movie 2" must not borrow "Movie"'s sub).
        if isSequelMismatch(video.titleTokens, sub.titleTokens) { return nil }

        if video.episode != nil {
            // T3 — same episode+season (conflicts already excluded), drifted tags. Title must agree.
            guard titleAgrees(video.titleTokens, sub.titleTokens, episodeAnchored: true) else { return nil }
            if let lang = sub.language { return lang }
            if let group = sub.groupTag, group != video.groupTag { return group }
            return "ep\(video.episode!)"
        } else {
            // T4 — no episode either side. Title must agree (year conflict already excluded).
            guard titleAgrees(video.titleTokens, sub.titleTokens, episodeAnchored: false) else { return nil }
            return sub.language ?? "Default"
        }
    }

    // MARK: - Title agreement

    /// G8 inverse. Titles agree when cores are equal, or overlap enough (Jaccard ≥ 0.5 with a shared
    /// word). An episode-only side (no title tokens) is trusted only when an episode anchors the match.
    private static func titleAgrees(_ a: Set<String>, _ b: Set<String>, episodeAnchored: Bool) -> Bool {
        if a == b { return true }
        if a.isEmpty || b.isEmpty { return episodeAnchored }
        let shared = a.intersection(b)
        guard !shared.isEmpty else { return false }
        let jaccard = Double(shared.count) / Double(a.union(b).count)
        return jaccard >= 0.5
    }

    /// G7. True when the titles differ *only* by one-sided sequel markers — a bare arabic integer
    /// ("Movie 2", "Movie 7") or a roman numeral ("Movie VII"). This catches the case where the shared
    /// words alone clear the Jaccard floor (so titleAgrees would wrongly pass); fully-disjoint titles
    /// ("Movie2" vs "Movie") are already rejected by titleAgrees, so no concatenated-token branch is needed.
    private static func isSequelMismatch(_ a: Set<String>, _ b: Set<String>) -> Bool {
        if a == b { return false }
        return a.symmetricDifference(b).allSatisfy { isSequelMarker($0) }
    }

    /// A bare arabic integer (any length — sequels aren't capped) or a roman-numeral sequel token.
    private static func isSequelMarker(_ token: String) -> Bool {
        (!token.isEmpty && token.allSatisfy(\.isNumber)) || romanSequelTokens.contains(token)
    }

    // MARK: - Episode extraction

    private static func extractEpisode(stem: String, bracketInners: [String], year: Int?) -> (episode: Int?, end: Int?, season: Int?) {
        // (a) SxxExx (with optional -Eyy span).
        if let m = try? seasonEpRegex.firstMatch(in: stem),
           let s = m.output[1].substring.flatMap({ Int($0) }),
           let e = m.output[2].substring.flatMap({ Int($0) }) {
            let end = m.output[3].substring.flatMap { Int($0) } ?? e
            return (e, end, s)
        }
        // (b) 1x05.
        if let m = try? seasonXRegex.firstMatch(in: stem),
           let s = m.output[1].substring.flatMap({ Int($0) }),
           let e = m.output[2].substring.flatMap({ Int($0) }) {
            return (e, e, s)
        }
        // (c) bracketed all-digits (optionally `vN` versioned) — exclude CRC32 (8 hex) and years.
        for inner in bracketInners {
            if inner.count == 8, inner.allSatisfy(\.isHexDigit) { continue }  // CRC32, never an episode
            let base = inner.split(separator: "v", maxSplits: 1).first.map(String.init) ?? inner
            guard !base.isEmpty, base.count <= 4, base.allSatisfy(\.isNumber), let n = Int(base) else { continue }
            if (1900...2099).contains(n) { continue }   // year, not episode
            return (n, n, nil)
        }
        // (d) dash-delimited " - 01 " (optional batch range " - 12-13 " → group 2 is the span end).
        if let m = try? dashEpRegex.firstMatch(in: stem),
           let e = m.output[1].substring.flatMap({ Int($0) }), !(1900...2099).contains(e) {
            let end = m.output[2].substring.flatMap { Int($0) } ?? e
            return (e, end, nil)
        }
        // (e) explicit E01 / EP01 / Episode 1.
        if let m = try? explicitEpRegex.firstMatch(in: stem),
           let e = m.output[1].substring.flatMap({ Int($0) }), !(1900...2099).contains(e) {
            return (e, e, nil)
        }
        return (nil, nil, nil)
    }

    // MARK: - Helpers

    /// First capture-group integer of `regex` in `s`, if any.
    private static func firstInt(_ regex: Regex<AnyRegexOutput>, in s: String, group: Int) -> Int? {
        guard let m = try? regex.firstMatch(in: s), group < m.output.count else { return nil }
        return m.output[group].substring.flatMap { Int($0) }
    }

    /// Recognised multi-language combo token (`jptc`, `jpsc`, `big5gb`). Separator-joined combos
    /// like `sc_jp` are split into atomic codes by the tokenizer before lookup, so only these
    /// no-separator combos need listing here.
    private static func combinationLanguage(_ token: String) -> String? {
        let combos: Set<String> = ["jptc", "jpsc", "big5gb"]
        return combos.contains(token) ? token : nil
    }

    /// A language code, language combo, or subtitle qualifier — i.e. a token that labels a track
    /// rather than naming the content. Excluded from title identity and episode-only detection.
    private static func isLanguageToken(_ token: String) -> Bool {
        languageTokens.contains(token) || subtitleFlagTokens.contains(token) || combinationLanguage(token) != nil
    }
}
