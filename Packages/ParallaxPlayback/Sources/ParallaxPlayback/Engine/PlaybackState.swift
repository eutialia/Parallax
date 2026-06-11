import Foundation
import CoreMedia

public enum PlaybackState: Sendable {
    case idle
    case loading
    case ready(duration: CMTime, tracks: TrackInventory)
    /// `buffered` is the absolute media time the contiguous buffer around the
    /// playhead extends to (AVKit: end of the `loadedTimeRanges` range containing
    /// the position) — the progress bar's middle "instant seek" layer. Nil when
    /// the engine doesn't report buffer ranges (VLC).
    case playing(position: CMTime, duration: CMTime, buffered: CMTime?)
    case paused(position: CMTime, duration: CMTime, buffered: CMTime?)
    /// Mid-stream stall: the user's intent is "playing" but the engine is waiting
    /// for media (AVKit: `timeControlStatus == .waitingToPlayAtSpecifiedRate`) —
    /// after a seek past the buffer, or a network underrun. Distinct from
    /// `.loading` (no stream yet) and `.paused` (user intent). AVKit-only: VLC's
    /// `state == .buffering` fires bogusly during normal playback
    /// (VideoLAN VLCKit#578), so the VLC engine never emits this.
    case buffering(position: CMTime, duration: CMTime, buffered: CMTime?)
    case ended
    case failed(PlaybackError)
}
