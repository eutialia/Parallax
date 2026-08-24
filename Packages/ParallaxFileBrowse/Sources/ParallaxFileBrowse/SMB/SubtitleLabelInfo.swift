import Foundation
import ParallaxCore

/// Structured reading of a sidecar-subtitle label (`SMBSubtitleMatch.label`) — the
/// filename-derived tag soup like `"zh.hi"`, `"en.forced"`, `"jptc"` — so menus can
/// name the track the way server-backed sources do ("Chinese" + an SDH badge)
/// instead of echoing the raw suffix.
///
/// The token vocabulary is SHARED with `SubtitleMatcher` (its language sets derive
/// from the tables here), so a token the matcher recognises as a language is always
/// one this parser can translate, and vice versa. One deliberate difference: `hi`
/// reads as hearing-impaired HERE but is not a matcher flag token — inside a label
/// the tokens are already known to be track qualifiers, while the matcher scans full
/// stems where "hi" collides with ordinary title words. (Hindi is `hin`, per the
/// same convention Jellyfin's sidecar naming uses.)
public struct SubtitleLabelInfo: Sendable, Equatable {
    /// BCP-47 tags in source order, deduped. Script subtags are kept (`zh-Hans` vs
    /// `zh-Hant`) — the Simplified/Traditional split is exactly what fansub tags
    /// like `chs`/`cht` exist to communicate.
    public let languageTags: [String]
    public let isSDH: Bool
    public let isForced: Bool
    /// Content qualifiers spelled out for display ("Signs", "Songs", "Commentary").
    public let descriptors: [String]

    public init(label: String) {
        var tags: [String] = []
        var sdh = false
        var forced = false
        var descriptors: [String] = []
        func appendTag(_ tag: String) {
            if !tags.contains(tag) { tags.append(tag) }
        }
        // "-" is NOT a separator here: a hyphenated component is a BCP-47-shaped
        // unit ("en-gb", "zh-Hant") that must resolve whole — token-splitting it
        // would misread the region GB as the fansub token for Simplified Chinese.
        let components = label.lowercased().components(separatedBy: Self.separators).filter { !$0.isEmpty }
        var index = 0
        // "zh_Hans" tokenizes to "zh" + "hans" — the script arrives as its own
        // component and has to be folded back onto the language it qualifies.
        // Only hans/hant: every other neighbouring token ("forced", "hi") is a
        // qualifier in its own right and must survive the look-ahead.
        func withFollowingScript(_ tag: String) -> String {
            guard !tag.contains("-"), index < components.count else { return tag }
            switch components[index] {
            case "hans": index += 1; return tag + "-Hans"
            case "hant": index += 1; return tag + "-Hant"
            default: return tag
            }
        }
        while index < components.count {
            let component = components[index]
            index += 1
            if component.contains("-") {
                // All-or-nothing: either every subtag reads as language+script/
                // region ("zh-tw") or the component contributes nothing at all —
                // a release-group tag like "sc-team" must not surface a bogus
                // "Chinese, Simplified" (with a bogus language code to match).
                if let tag = Self.bcp47Tag(component, widened: true) { appendTag(tag) }
            } else if let tag = Self.languageTagByToken[component] {
                appendTag(withFollowingScript(tag))
            } else if let combo = Self.comboLanguageTags[component] {
                combo.forEach(appendTag)
            } else if Self.sdhTokens.contains(component) {
                sdh = true
            } else if component == "forced" {
                forced = true
            } else if let word = Self.descriptorWords[component] {
                if !descriptors.contains(word) { descriptors.append(word) }
            } else if let tag = Self.isoLanguageTag(component) {
                // Last, so a qualifier token ICU also reads as a language ("hi",
                // "sdh") keeps its label meaning.
                appendTag(withFollowingScript(tag))
            }
        }
        self.languageTags = tags
        self.isSDH = sdh
        self.isForced = forced
        self.descriptors = descriptors
    }

    /// A lowercased hyphenated component as one BCP-47 tag, or nil when any
    /// subtag doesn't parse as script/region. Chinese region conventions carry
    /// script information ("zh-cn" means Simplified as surely as "chs" does), so
    /// they resolve to the script form the display layer distinguishes.
    ///
    /// Internal (not `private`) so `SubtitleMatcher` can probe whether a hyphenated
    /// filename component resolves whole *before* hyphen-splitting it — see the
    /// language pass in `SubtitleMatcher.NameModel.init`. The matcher scans full
    /// stems, so ITS calls keep the curated base vocabulary (default): with the
    /// widened one, a title token like "So-So" or "Man-GB" would read as a
    /// language. Only the label parser above opts into `widened`.
    static func bcp47Tag(_ component: String, widened: Bool = false) -> String? {
        let subtags = component.split(separator: "-").map(String.init)
        guard let base = subtags.first,
              var tag = Self.languageTagByToken[base] ?? (widened ? Self.isoLanguageTag(base) : nil)
        else { return nil }
        for subtag in subtags.dropFirst() {
            if subtag == "hans" || subtag == "hant" {
                if !tag.contains("-") { tag += subtag == "hans" ? "-Hans" : "-Hant" }
            } else if subtag.count == 2 && subtag.allSatisfy(\.isLetter)
                        || subtag.count == 3 && subtag.allSatisfy(\.isNumber) {
                // Region subtag. Only Chinese regions refine the tag (script is
                // what the menu distinguishes); others add nothing to a chip name.
                if tag == "zh" {
                    if ["cn", "sg", "my"].contains(subtag) { tag = "zh-Hans" }
                    if ["tw", "hk", "mo"].contains(subtag) { tag = "zh-Hant" }
                }
            } else {
                return nil
            }
        }
        return tag
    }

    /// Any ISO 639-1/639-2 (B or T) code, as the alpha-2 tag when one exists —
    /// matching the curated table's `en`/`ja` style — else alpha-3. Nil for
    /// anything ICU doesn't know as a language, which is what keeps release-tag
    /// words ("raw", "dvd", "web") out.
    ///
    /// LABEL CONTEXT ONLY. `SubtitleMatcher` derives its stem-scanning vocabulary
    /// from `languageTagByToken` and must keep doing so: algorithmic recognition
    /// over a whole filename would read ordinary title words ("The.Mac.and.Me",
    /// "War", "Man") as languages. Inside a label the tokens are already known to
    /// be track qualifiers, so the wider vocabulary is safe — which is why only
    /// the label parser (and its `widened` `bcp47Tag` calls) reaches this, never
    /// the matcher's stem probe.
    static func isoLanguageTag(_ token: String) -> String? {
        guard (2...3).contains(token.count), token.allSatisfy(\.isLetter),
              let alpha3 = TrackLanguage.normalized(token),
              Locale.LanguageCode(alpha3).identifier(.alpha3) != nil
        else { return nil }
        if let alpha2 = Locale.LanguageCode(alpha3).identifier(.alpha2), alpha2.count == 2 {
            return alpha2
        }
        return alpha3
    }

    /// The menu/chip name this label earns: localized language names (dual-language
    /// tracks join with " + "), content qualifiers in parens. A label that carries
    /// no recognised token at all ("Default", a release-group tag, "ep12") returns
    /// `fallback` — those raw strings are already the best available name.
    public func displayName(fallback: String, locale: Locale = .current) -> String {
        let names = languageTags.compactMap { TrackDisplay.languageName($0, locale: locale) }
        var name = names.joined(separator: " + ")
        let qualifier = descriptors.joined(separator: " & ")
        if name.isEmpty {
            name = qualifier
        } else if !qualifier.isEmpty {
            name += " (\(qualifier))"
        }
        return name.isEmpty ? fallback : name
    }

    // MARK: - Shared vocabulary (SubtitleMatcher derives its language sets from these)

    /// The matcher's separator set minus "-" (hyphenated components resolve whole,
    /// see `init`). Brackets included: a T2 suffix is the filename tail verbatim,
    /// so "Movie.[chs].srt" labels as "[chs]".
    private static let separators = CharacterSet(charactersIn: " ._+&[](){}")

    /// Atomic language token → BCP-47 tag.
    static let languageTagByToken: [String: String] = [
        "en": "en", "eng": "en", "english": "en",
        "ja": "ja", "jp": "ja", "jpn": "ja", "japanese": "ja",
        "zh": "zh",
        "chs": "zh-Hans", "sc": "zh-Hans", "gb": "zh-Hans", "gbsc": "zh-Hans",
        "cht": "zh-Hant", "tc": "zh-Hant", "big5": "zh-Hant",
        "ko": "ko", "kor": "ko", "korean": "ko",
        "fr": "fr", "fra": "fr", "fre": "fr",
        "es": "es", "spa": "es",
        "de": "de", "ger": "de", "deu": "de",
        "it": "it", "ita": "it",
        "pt": "pt", "por": "pt",
        "ru": "ru", "rus": "ru",
        "ar": "ar", "ara": "ar",
        "nl": "nl", "nld": "nl", "dut": "nl",
    ]

    /// No-separator combo token → its language tags (dual-language fansub releases).
    static let comboLanguageTags: [String: [String]] = [
        "jptc": ["ja", "zh-Hant"],
        "jpsc": ["ja", "zh-Hans"],
        "big5gb": ["zh-Hant", "zh-Hans"],
    ]

    /// Hearing-impaired markers. Label-context only — see the type doc for why the
    /// matcher's stem scan excludes `hi`.
    private static let sdhTokens: Set<String> = ["sdh", "cc", "hi"]

    private static let descriptorWords: [String: String] = [
        "signs": "Signs", "songs": "Songs",
        "commentary": "Commentary", "comm": "Commentary",
    ]
}
