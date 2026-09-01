import Foundation
import ParallaxCore

/// Pure decision for the AVKit→VLC reactive fallback. Some MP4-family files pass the
/// SMB pre-flight probe (or arrive as an ordinary Jellyfin direct-play stream) but fail
/// at DECODE time — a damaged bitstream or an open-GOP cut invisible to a container-level
/// probe. AVKit surfaces that as a terminal `.failed` state, mid-load or mid-playback
/// (`AVKitEngine`'s `AVPlayerItem.status` KVO fires on either). This decides whether THAT
/// failure earns a one-shot re-route to VLCKit on the SAME asset, or should fall through
/// to the normal error scrim.
///
/// No I/O, no state: the caller (`PlayerViewModel`) owns the one-shot flag and passes it
/// in fresh on every failure.
public enum ReactiveFallback {
    /// Containers this fallback covers — MP4-family only. Never HLS (a Jellyfin transcode
    /// failing is a server problem the retry can't fix, not a file defect) and never a
    /// container the hints left unknown (no evidence it's the class of defect this targets).
    private static let eligibleContainers: Set<Container> = [.mp4, .mov]

    /// - Parameters:
    ///   - currentEngine: the engine that just reported the terminal failure.
    ///   - container: the failed asset's container, from its `PlaybackHints`.
    ///   - alreadyRerouted: whether this playback session already spent its one re-route.
    ///   - error: the failure kind. The stall watchdog's `.networkStalled` is a link
    ///     problem, not a decode defect — rerouting would tear down a working engine and
    ///     mask the honest stall scrim. `.assetNotPlayable` (the decode-failure KVO) and
    ///     `.loadTimedOut` (the load watchdog) both reroute: a load-wedge retry on VLC is
    ///     bounded and sometimes rescues files AVKit hangs on. The two were one case until
    ///     the watchdog got its own, and splitting them must not silently drop that half.
    public static func shouldReroute(
        currentEngine: PlaybackEngineID,
        container: Container?,
        alreadyRerouted: Bool,
        error: PlaybackError
    ) -> Bool {
        guard !alreadyRerouted, currentEngine == .avKit, let container,
              error == .assetNotPlayable || error == .loadTimedOut
        else { return false }
        return eligibleContainers.contains(container)
    }
}
