import Foundation
import ParallaxCore

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
    static func resolvedName(
        displayName: String,
        languageCode: String?,
        kind: Kind,
        ordinal: Int
    ) -> String {
        nonGenericDisplayName(displayName) ?? TrackDisplay.languageName(languageCode)
            ?? "\(kind.label) \(ordinal)"
    }

    /// Just the first tier: the option's own name when it isn't a placeholder,
    /// else `nil`. Kept distinct from the language tier so a caller can slot a
    /// richer source (e.g. server metadata) ahead of a bare language name.
    static func nonGenericDisplayName(_ displayName: String) -> String? {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isGenericPlaceholder(trimmed) else { return nil }
        return trimmed
    }

    /// AVFoundation names an option with no name of its own by its language, and one of
    /// undetermined language by the locale's name for `und` ("Unknown language"); a manifest's
    /// own placeholder reads "Unknown". None of these names the track.
    private static func isGenericPlaceholder(_ name: String) -> Bool {
        let lowered = name.lowercased()
        return lowered == "unknown" || lowered == "und" || lowered == "undetermined"
            || lowered == Locale.current.localizedString(forLanguageCode: "und")?.lowercased()
    }
}
