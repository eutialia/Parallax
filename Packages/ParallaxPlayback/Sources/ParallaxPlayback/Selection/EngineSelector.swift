import Foundation
import ParallaxCore

/// Pure routing function. No I/O, no state. Exhaustively matrix-tested.
///
/// Priority order (first match wins):
///   1. `hints.scheme == "smb"` → `.vlcKit`  (SMB streams the app didn't bridge —
///      AVPlayer cannot open `smb://`; bridged SMB arrives as `http` with probed hints)
///   2. `hints.subtitleFormats` contains a non-AVPlayer-renderable format → `.vlcKit`
///   3. `hints.container` is non-nil and not in the AVPlayer whitelist → `.vlcKit`
///   4. `hints.videoCodec` is non-nil and not in the AVPlayer whitelist → `.vlcKit`
///   5. `hints.audioCodec` is non-nil and not in the AVPlayer whitelist → `.vlcKit`
///   6. Otherwise → `.avKit`
///
/// Three production sources feed `hints`:
///   - Jellyfin direct-play/direct-stream: `PlayerViewModel.deliveredHints` carries the
///     server-negotiated container/codecs of the delivered stream.
///   - Jellyfin transcode: the same builder pins `container: .hls` (codec fields nil) —
///     an HLS transcode always routes to AVKit.
///   - SMB: `SMBPlaybackResolver.route` builds them from the container probe — a
///     bridgeable file arrives as scheme `http` + probed container/codecs, everything
///     else (probe failure, incomplete file, unknown codec) stays scheme `smb`.
public enum EngineSelector {

    // MARK: — Selection

    public static func select(hints: PlaybackHints) -> PlaybackEngineID {
        // 1. SMB scheme → VLC (AVPlayer cannot open smb:// URIs)
        if hints.scheme == "smb" {
            return .vlcKit
        }

        // 2. Non-AVPlayer-renderable subtitle format present → VLC
        //    ASS/SSA require libass; PGS and VobSub are image-based bitmaps.
        let hasNonAVKitSubtitle = hints.subtitleFormats.contains {
            !PlaybackCapabilityMatrix.avKitSubtitleFormats.contains($0)
        }
        if hasNonAVKitSubtitle {
            return .vlcKit
        }

        // 3. Container known and not in the AVPlayer set → VLC
        if let container = hints.container,
           !PlaybackCapabilityMatrix.avKitContainers.contains(container) {
            return .vlcKit
        }

        // 4. Video codec known and not in the AVPlayer set → VLC
        if let video = hints.videoCodec,
           !PlaybackCapabilityMatrix.avKitVideoCodecs.contains(video) {
            return .vlcKit
        }

        // 5. Audio codec known and not in the AVPlayer set → VLC
        if let audio = hints.audioCodec,
           !PlaybackCapabilityMatrix.avKitAudioCodecs.contains(audio) {
            return .vlcKit
        }

        // 6. All checks passed → AVKit
        return .avKit
    }
}
