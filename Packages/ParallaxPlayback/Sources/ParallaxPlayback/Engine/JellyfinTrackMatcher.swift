import Foundation
import ParallaxCore

/// Resolves a track's display name, preferring the engine's own naming and
/// falling back to the server's authoritative metadata only when the playback
/// source couldn't name the track itself.
///
/// Ordering matters: a transcode manifest frequently strips per-rendition
/// names/languages (so AVFoundation yields "Unknown"), while the server's
/// `MediaStreamInfo` has the real title. But where the manifest *does* carry a
/// good name (e.g. "Chinese, Traditional (Taiwan)"), that's kept — the server's
/// terser "Chinese" would be a regression.
enum JellyfinTrackMatcher {
    static func name(
        kind: AVKitTrackNaming.Kind,
        optionDisplayName: String,
        optionLanguage: String?,
        ordinal: Int,
        optionCount: Int,
        streams: [MediaStreamInfo],
        defaultStreamIndex: Int?,
        locale: Locale = .current
    ) -> String {
        // 1. The manifest named it — trust the option's own name.
        if let name = AVKitTrackNaming.nonGenericDisplayName(optionDisplayName) {
            return name
        }
        // 2. The manifest dropped the name — borrow the server's richer title
        //    (e.g. "English - TrueHD 7.1" beats a bare "English").
        if let title = serverTitle(
            kind: kind,
            optionLanguage: optionLanguage,
            optionCount: optionCount,
            streams: streams,
            defaultStreamIndex: defaultStreamIndex
        ) {
            return title
        }
        // 3. No server match — fall to a localized language name, then "Audio N".
        return AVKitTrackNaming.resolvedName(
            displayName: optionDisplayName,
            languageCode: optionLanguage,
            kind: kind,
            ordinal: ordinal,
            locale: locale
        )
    }

    private static func serverTitle(
        kind: AVKitTrackNaming.Kind,
        optionLanguage: String?,
        optionCount: Int,
        streams: [MediaStreamInfo],
        defaultStreamIndex: Int?
    ) -> String? {
        let candidates = streams.filter { sameKind(kind, $0.kind) }

        // A single rendition in the manifest is the one the server transcoded —
        // identify it by the server's chosen default index, or fall through to
        // the lone candidate.
        if optionCount == 1 {
            if let idx = defaultStreamIndex,
               let stream = candidates.first(where: { $0.index == idx }) {
                return cleaned(stream.displayTitle)
            }
            if candidates.count == 1 {
                return cleaned(candidates.first?.displayTitle)
            }
        }

        // Multiple renditions: match on language (the only reliable join when the
        // manifest dropped names) — but only when it is UNAMBIGUOUS. If several
        // server streams share the language (e.g. two "zho" streams that differ
        // only by script, Traditional vs Simplified), language can't disambiguate
        // them, so fall through to AVFoundation's own script-aware locale name
        // rather than slapping the first stream's title on every variant.
        if let language = optionLanguage {
            let matches = candidates.filter { sameLanguage($0.language, language) }
            if matches.count == 1 {
                return cleaned(matches[0].displayTitle)
            }
        }
        return nil
    }

    private static func sameKind(_ kind: AVKitTrackNaming.Kind, _ streamKind: MediaStreamInfo.Kind) -> Bool {
        switch kind {
        case .audio: return streamKind == .audio
        case .subtitle: return streamKind == .subtitle
        }
    }

    private static func sameLanguage(_ a: String?, _ b: String?) -> Bool {
        guard let a, let b else { return false }
        if a.caseInsensitiveCompare(b) == .orderedSame { return true }
        // Jellyfin reports ISO 639-2/T ("eng"); AVFoundation's extendedLanguageTag
        // yields BCP-47 ("en", "zh-Hant"). Normalize both to alpha-3 so the join
        // doesn't silently fail — without this every "eng" vs "en" pair missed and
        // the track fell back to a bare "Audio N" ordinal.
        let a3 = Locale.Language(identifier: a).languageCode?.identifier(.alpha3)
        let b3 = Locale.Language(identifier: b).languageCode?.identifier(.alpha3)
        return a3 != nil && a3 == b3
    }

    /// Trims, drops a trailing " - Default" (the menu marks the active track
    /// already), and returns nil for an empty title so the caller falls through.
    private static func cleaned(_ title: String?) -> String? {
        guard let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return MediaStreamInfo.strippingDefaultSuffix(trimmed)
    }
}
