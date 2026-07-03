import Foundation

/// Optional AVKit startup/buffering knobs for on-device time-to-first-frame tuning.
/// Every field is `nil` by default (`.systemDefault`) — a `nil` field means the
/// corresponding `AVPlayerItem`/`AVPlayer` property is left completely untouched by
/// `AVKitEngine`, not merely set to its documented default. That distinction matters:
/// touching a property at all can pin behavior against a future OS default change,
/// so the shipping profile must apply nothing.
///
/// Only `AVKitEngine` reads this — `VLCKitEngine` has its own buffering knobs and is
/// untouched by this type.
public struct StartupTuning: Sendable, Equatable {
    /// Seconds of forward buffer AVFoundation should target before/while playing.
    /// `nil` = leave `AVPlayerItem.preferredForwardBufferDuration` untouched (system
    /// heuristic).
    public let preferredForwardBufferSeconds: Double?

    /// `nil` = leave `AVPlayer.automaticallyWaitsToMinimizeStalling` untouched (`true`,
    /// the system default). Note: `AVKitEngine.play()` resumes via
    /// `playImmediately(atRate:)`, which already bypasses this gate for the initial
    /// play — this knob only affects post-seek/mid-stream rebuffering behavior.
    ///
    /// Setting this `false` (the `fastStartEager` profile) changes how a mid-stream
    /// stall reports itself: per Apple's docs, `timeControlStatus` flips to `.paused`
    /// instead of `.waitingToPlayAtSpecifiedRate`, which would silently defeat
    /// `AVKitEngine`'s KVO-driven `StallWatchdog` arm. `AVKitEngine` covers that case by
    /// also observing `AVPlayerItem.playbackStalledNotification` — Apple's docs confirm
    /// it posts ONLY when this property is `false` — so the eager profile stays covered
    /// (see `AVKitEngine.handleStalledNotification`, final-review I1).
    public let automaticallyWaitsToMinimizeStalling: Bool?

    public static let systemDefault = StartupTuning(
        preferredForwardBufferSeconds: nil,
        automaticallyWaitsToMinimizeStalling: nil
    )

    public init(preferredForwardBufferSeconds: Double?, automaticallyWaitsToMinimizeStalling: Bool?) {
        self.preferredForwardBufferSeconds = preferredForwardBufferSeconds
        self.automaticallyWaitsToMinimizeStalling = automaticallyWaitsToMinimizeStalling
    }
}
