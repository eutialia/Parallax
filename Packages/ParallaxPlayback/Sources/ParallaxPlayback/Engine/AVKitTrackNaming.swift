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
        meaningfulName(displayName: displayName, languageCode: languageCode, locale: locale)
            ?? "\(kind.label) \(ordinal)"
    }

    /// The first two naming tiers — a non-placeholder `displayName`, else a
    /// localized language name — or `nil` when neither is usable.
    static func meaningfulName(
        displayName: String,
        languageCode: String?,
        locale: Locale = .current
    ) -> String? {
        nonGenericDisplayName(displayName) ?? localizedLanguageName(languageCode, locale: locale)
    }

    /// Just the first tier: the option's own name when it isn't a placeholder,
    /// else `nil`. Kept distinct from the language tier so a caller can slot a
    /// richer source (e.g. server metadata) ahead of a bare language name.
    static func nonGenericDisplayName(_ displayName: String) -> String? {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isGenericPlaceholder(trimmed) else { return nil }
        return trimmed
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
