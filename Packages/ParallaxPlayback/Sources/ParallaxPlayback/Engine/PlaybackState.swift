import Foundation
import CoreMedia

/// Where a position-carrying beat's `position` came from.
///
/// The seek-settle contract used to be a boolean, and it conflated two facts an engine knows
/// apart: "I am guessing forward off my own seek target" and "my clock has not caught up with
/// my own seek yet". Both mean *don't treat this as a landing*, but only the first is safe to
/// put on screen — the second is the position the user seeked AWAY from. Three values keep
/// "may I show this?" and "is this evidence?" separate, which is what a consumer actually asks.
public enum PositionProvenance: Sendable, Equatable {
    /// An observed decoder clock with no seek of the engine's own outstanding. The ONLY value
    /// that counts as evidence a seek landed, and the only one a consumer may treat as
    /// authoritative about where the media is.
    case observed
    /// The engine's forward estimate from its OWN outstanding seek target: the target echoed
    /// back, an extrapolation off it, a starvation scrim pinned at it, a pause frozen on it.
    /// DISPLAY-SAFE — the picture is at (or running from) this position, so a bar that follows
    /// it moves with the video — but never evidence: it says nothing about whether the seek
    /// has resolved.
    case projected
    /// The engine's clock, which has not caught up with the engine's own outstanding seek: it
    /// describes where the media was BEFORE the seek. Neither display-safe nor evidence —
    /// showing it drags the bar backwards under a picture that has already moved.
    case stale
}

/// **The seek-settle contract.** Every position-carrying case (`.playing`, `.paused`,
/// `.buffering`) carries a `PositionProvenance` answering one question: where did `position`
/// come from — the engine's clock, or the engine's own guess off a seek it has not resolved?
///
/// * `.observed` is the only beat that is evidence. After `seek(to:)`, the first `.observed`
///   beat carries a clock at or after the LATEST target.
/// * `.projected` is display-safe and nothing more: show it, conclude nothing from it.
/// * `.stale` is neither — a consumer must not show it and must not conclude from it.
/// * Overlapping seeks produce nothing `.observed` until the LATEST one resolves; a
///   superseded seek never produces one.
/// * If an engine abandons a seek it publishes an honest raw clock as `.observed` — never a
///   silent republish of the pre-seek clock dressed up as a landing.
/// * An engine that cannot tell reports `.stale`, the safe answer in both directions: a
///   consumer that trusts a stale beat corrupts a position, while one that distrusts an
///   observed beat only waits a tick longer.
public enum PlaybackState: Sendable {
    case idle
    case loading
    case ready(duration: CMTime, tracks: TrackInventory)
    /// `buffered` is the absolute media time the contiguous buffer around the
    /// playhead extends to (AVKit: end of the `loadedTimeRanges` range containing
    /// the position) — the progress bar's middle "instant seek" layer. Nil when
    /// the engine doesn't report buffer ranges (VLC).
    ///
    /// `provenance` is the seek-settle contract every position-carrying case carries — see
    /// the note above the enum. Deliberately NOT defaulted: `.observed` is the strongest claim
    /// in the contract ("my clock, no seek of mine outstanding"), and as a zero-config default
    /// a forgotten label compiles into exactly that claim at whatever site forgot it. Test
    /// construction stays terse through the `PlaybackState` fixture factories in
    /// `ParallaxPlaybackTestSupport`, which default it where a scripted beat really is a clock.
    case playing(position: CMTime, duration: CMTime, buffered: CMTime?,
                 provenance: PositionProvenance)
    case paused(position: CMTime, duration: CMTime, buffered: CMTime?,
                provenance: PositionProvenance)
    /// Mid-stream stall: the user's intent is "playing" but the engine is waiting
    /// for media (AVKit: `timeControlStatus == .waitingToPlayAtSpecifiedRate`)
    /// after a seek past the buffer, or a network underrun. Distinct from
    /// `.loading` (no stream yet) and `.paused` (user intent). BOTH engines emit it:
    /// VLC derives it from its own poll (frozen clock plus frozen demux, a seek whose
    /// fetch stopped, a rate-change re-decode) rather than from `state == .buffering`,
    /// which fires bogusly during normal playback (VideoLAN VLCKit#578). Only the
    /// buffered RANGES are AVKit-only; the VLC engine always ships `buffered: nil`.
    case buffering(position: CMTime, duration: CMTime, buffered: CMTime?,
                   provenance: PositionProvenance)
    case ended
    case failed(PlaybackError)
}
