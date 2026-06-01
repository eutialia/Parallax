import Foundation
import ParallaxCore

/// The delivery decision for a single external subtitle track.
/// - `avKitSidecar`: pass the URL to `AVURLAsset`'s external subtitle options.
/// - `vlcSlave`: call `VLCMediaPlayer.addPlaybackSlave(_:type:enforce:)` with `.subtitle`.
/// - `embedded`: no action — the engine enumerates the track from its internal inventory.
/// - `unsupported`: the engine cannot render this format; log and skip.
public enum SubtitleDelivery: Sendable {
    case avKitSidecar(url: URL)
    case vlcSlave(url: URL, enforce: Bool)
    case embedded
    case unsupported
}

/// Pure routing function: maps an `ExternalSubtitle` + engine identity to the
/// concrete delivery mechanism. No I/O; no state.
///
/// | Engine    | Format                      | Delivery        |
/// |-----------|-----------------------------|-----------------|
/// | `.vlcKit` | any external format         | `.vlcSlave`     |
/// | `.avKit`  | `.srt` / `.vtt`             | `.avKitSidecar` |
/// | `.avKit`  | `.ass` / `.pgs` / `.vobsub` | `.unsupported`  |
///
/// Embedded subtitles (no `ExternalSubtitle` entry) are left to the engine's own
/// track inventory — not a `SubtitleResolver` concern.
public enum SubtitleResolver {

    /// Resolve the delivery mode for a single external subtitle.
    public static func resolve(
        subtitle: ExternalSubtitle,
        engine: PlaybackEngineID
    ) -> SubtitleDelivery {
        switch engine {
        case .vlcKit:
            return .vlcSlave(url: subtitle.url, enforce: subtitle.isForced)
        case .avKit:
            // Single source of truth for the AVKit-native set lives in the matrix;
            // a private copy here would silently diverge when a format is added.
            if PlaybackCapabilityMatrix.avKitSubtitleFormats.contains(subtitle.format) {
                return .avKitSidecar(url: subtitle.url)
            } else {
                return .unsupported
            }
        }
    }

    /// Resolve all subtitles in a list, preserving order.
    public static func resolveAll(
        subtitles: [ExternalSubtitle],
        engine: PlaybackEngineID
    ) -> [SubtitleDelivery] {
        subtitles.map { resolve(subtitle: $0, engine: engine) }
    }
}
