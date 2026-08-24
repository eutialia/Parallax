import Foundation
import ParallaxCore

/// Jellyfin's own reading of a language preference — its dialect, not a general
/// one, which is why this lives here and not in ParallaxCore.
///
/// The server resolves `SubtitleLanguagePreference` two different ways. For the
/// nine hyphenated culture rows below it matches that ONE tag, case-insensitively
/// and exactly; for anything else it expands to the ISO 639-2 terminologic +
/// bibliographic pair ("zho"/"chi") and only compares against DASHLESS stream
/// tags. So the two vocabularies never meet: a stored "zho" can't select a
/// `zh-Hans` external sub, and a stored "zh-Hans" can't select an embedded "zho".
/// Persisting a culture-row pick script-stripped would orphan exactly the tracks
/// the user just chose.
enum JellyfinLanguageTag {
    /// Culture rows the server matches exact-only, keyed by their lowercased form
    /// and valued in the canonical BCP-47 casing the server writes.
    ///
    /// Snapshot of every hyphenated lookup code in the server's
    /// `Emby.Server.Implementations/Localization/iso6392.txt` as of Jellyfin
    /// 10.11 (branch `release-10.11.z`) — re-diff against that file when bumping
    /// the supported server version. Drift is benign: an unlisted tag persists
    /// as alpha-3 and the resolve-time fallback still bridges it by base language.
    private static let cultureRows: [String: String] = [
        "zh-cn": "zh-CN", "zh-hans": "zh-Hans", "zh-tw": "zh-TW", "zh-hant": "zh-Hant",
        "zh-hk": "zh-HK", "pt-br": "pt-BR", "pt-pt": "pt-PT", "fr-ca": "fr-CA",
        "es-419": "es-419",
    ]

    /// The value to persist for a picked track's language tag: the culture row
    /// verbatim when the tag is one, alpha-3 otherwise.
    static func preferenceValue(for code: String?) -> String? {
        guard let code, !code.isEmpty else { return nil }
        let lowered = code.lowercased().replacingOccurrences(of: "_", with: "-")
        if let row = cultureRows[lowered] { return row }
        return TrackLanguage.normalized(code)
    }
}
