import Foundation
import ParallaxCore

/// Resolves a track's display name, preferring the engine's own naming and
/// falling back to the server's authoritative metadata only when the playback
/// source couldn't name the track itself.
///
/// Ordering matters: a transcode manifest frequently strips per-rendition
/// names/languages (so AVFoundation yields "Unknown"), while the server's
/// `MediaStreamInfo` has the real name. But where the manifest *does* carry a
/// good one (e.g. "Chinese, Traditional (Taiwan)"), that's kept — the server's
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
        // 2. The manifest dropped the name — borrow the server's clean track
        //    name (its own title, else a localized language name; codec detail
        //    is the menus' secondary line now, never the primary).
        if let name = matchedStream(
            kind: kind,
            optionLanguage: optionLanguage,
            optionCount: optionCount,
            streams: streams,
            defaultStreamIndex: defaultStreamIndex
        )?.preferredMenuName(locale: locale) {
            return name
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

    /// The server stream this manifest option corresponds to, when the join is
    /// unambiguous — also the source of the menus' codec/format detail line on
    /// the AVKit path (the manifest itself never carries codec metadata).
    static func matchedStream(
        kind: AVKitTrackNaming.Kind,
        optionLanguage: String?,
        optionCount: Int,
        streams: [MediaStreamInfo],
        defaultStreamIndex: Int?
    ) -> MediaStreamInfo? {
        let candidates = streams.filter { sameKind(kind, $0.kind) }

        // A single rendition in the manifest is the one the server transcoded —
        // identify it by the server's chosen default index, or fall through to
        // the lone candidate.
        if optionCount == 1 {
            if let idx = defaultStreamIndex,
               let stream = candidates.first(where: { $0.index == idx }) {
                return stream
            }
            if candidates.count == 1 {
                return candidates.first
            }
        }

        // Multiple renditions: match on language (the only reliable join when the
        // manifest dropped names) — but only when it is UNAMBIGUOUS. If several
        // server streams share the language (e.g. two "zho" streams that differ
        // only by script, Traditional vs Simplified), language can't disambiguate
        // them, so fall through to AVFoundation's own script-aware locale name
        // rather than slapping the first stream's title on every variant.
        // TrackLanguage normalizes both sides to alpha-3: Jellyfin reports ISO
        // 639-2 — often the BIBLIOGRAPHIC form ("fre"/"ger"/"chi"), which ICU
        // doesn't recognize — while AVFoundation's extendedLanguageTag yields
        // BCP-47 ("en", "zh-Hant"). Without the shared map, every B-form pair
        // missed and the track fell back to a bare "Audio N" ordinal.
        if let language = optionLanguage {
            let matches = candidates.filter { TrackLanguage.matches($0.language, language) }
            if matches.count == 1 {
                return matches[0]
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
}
