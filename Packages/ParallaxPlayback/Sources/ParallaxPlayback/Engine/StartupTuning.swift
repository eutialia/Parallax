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

    // NOTE: an `automaticallyWaitsToMinimizeStalling` knob (the "Fast Start (Eager)"
    // profile) was DELETED after on-device A/B (2026-07-08): under `waits == false` the
    // first `.playing` beat never landed (loading scrim wedged forever over a rendered
    // first frame) and it measured no faster than plain Fast Start. Don't resurrect it
    // without fixing first-beat emission; the `playbackStalledNotification` stall
    // fallback it required (final-review I1) was deleted with it — that notification
    // only posts when `waits == false`.

    public static let systemDefault = StartupTuning(
        preferredForwardBufferSeconds: nil
    )

    public init(preferredForwardBufferSeconds: Double?) {
        self.preferredForwardBufferSeconds = preferredForwardBufferSeconds
    }
}
