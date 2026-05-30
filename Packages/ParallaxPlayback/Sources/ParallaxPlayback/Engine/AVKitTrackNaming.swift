import Foundation

/// Pure naming/identity helpers for AVFoundation media-selection options.
///
/// HLS transcode manifests (e.g. Jellyfin's `master.m3u8`) frequently omit a
/// per-rendition `NAME`/`LANGUAGE`, so AVFoundation's `AVMediaSelectionOption.displayName`
/// collapses to a localized "Unknown". These helpers fall back to a localized
/// language name and finally a stable ordinal label, so the track menus never
/// show a bare "Unknown".
enum AVKitTrackNaming {
    enum Kind {
        case audio
        case subtitle

        var label: String {
            switch self {
            case .audio: return "Audio"
            case .subtitle: return "Subtitle"
            }
        }
    }

    /// Resolve a user-facing track name.
    ///
    /// Priority: a meaningful `displayName` → localized language name → "Audio N"/"Subtitle N".
    /// `ordinal` is the 1-based position among displayed tracks of this kind.
    /// `locale` controls the language-name localization (injected in tests so
    /// assertions don't depend on the host locale).
    static func resolvedName(
        displayName: String,
        languageCode: String?,
        kind: Kind,
        ordinal: Int,
        locale: Locale = .current
    ) -> String {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, !isGenericPlaceholder(trimmed) {
            return trimmed
        }
        if let name = localizedLanguageName(languageCode, locale: locale) {
            return name
        }
        return "\(kind.label) \(ordinal)"
    }

    /// AVFoundation returns a localized "Unknown" when an option has no name and
    /// no determinable language. We can't reproduce every locale's placeholder,
    /// but the common (English) device case shows literally "Unknown"; treat
    /// that and the undetermined ISO codes as non-meaningful so we fall through
    /// to a better label.
    static func isGenericPlaceholder(_ name: String) -> Bool {
        let lowered = name.lowercased()
        return lowered == "unknown" || lowered == "und" || lowered == "undetermined"
    }

    /// Localized language name for an ISO code, skipping the codes that carry no
    /// usable language (`und` undetermined, `mis` uncoded, `zxx` no linguistic
    /// content). Returns nil when the code is missing or non-linguistic.
    static func localizedLanguageName(_ code: String?, locale: Locale = .current) -> String? {
        guard let code, !code.isEmpty else { return nil }
        let lowered = code.lowercased()
        guard lowered != "und", lowered != "mis", lowered != "zxx" else { return nil }
        return locale.localizedString(forLanguageCode: code)
    }
}
