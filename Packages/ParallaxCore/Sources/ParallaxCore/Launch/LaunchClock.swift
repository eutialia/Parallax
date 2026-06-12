import Foundation

/// Maps real elapsed time onto the launch story's master clock, inserting the
/// sync-hold loop while background work (bootstrap / first Home fetch) is
/// pending. Production semantics from the handoff:
///
/// - The clock runs 0 → `holdStart`, then pins there looping whole "breath"
///   cycles until released.
/// - On release the CURRENT breath completes before the clock resumes — the
///   hold length is the elapsed hold quantized UP to whole cycles.
/// - A fast launch (released before the clock even reaches the hold) still
///   plays exactly one breath, so the chromatic "working" moment reads.
public enum LaunchClock {
    // ── Timing knobs ─────────────────────────────────────────────────────
    // THE place to set the animation's pace. Keyframes live in story-seconds
    // (LaunchTimeline) and never change; these two rates map them to real time.

    /// Story-seconds per real second for the icon-open and the sync-hold —
    /// the handoff's locked half speed (intro = 1.8s real, breath = 3s real).
    public static let speed = 0.5
    /// Story-seconds per real second once the hold releases: the resolve →
    /// merge → iris stretch. 1.0 plays it at full story speed (~2.55s real
    /// from release to full reveal) — twice the handoff preview's pace.
    public static let revealSpeed = 1.0

    /// Story time where the sync-hold loop pins — rings still sketched, before the merge.
    public static let holdStart = 0.9
    /// One breath of the sync-hold loop, in story-seconds.
    public static let breathLength = 1.5
    /// Story-seconds of motion; the revealed app holds after.
    public static let activeEnd = 3.45
    /// Locked flow intensity for the hold's eddy roll.
    public static let flowAmplitude = 0.8

    /// Story times where the revealed app's settle zoom (1.09 → 1.0) begins
    /// and ends — the `homeScale` track's stops, shared so the host's
    /// transform animation and the timeline can't drift apart.
    public static let settleStart = 2.6
    public static let settleEnd = 3.32
    /// The settle's real-seconds duration at the reveal pace.
    public static var settleRealDuration: Double { (settleEnd - settleStart) / revealSpeed }

    /// Real seconds of intro before the clock reaches the hold point.
    static var introRealLength: Double { holdStart / speed }

    /// Raw story time (hold not yet subtracted) for a real-time offset,
    /// in the intro/hold domain — pre-release bookkeeping only.
    public static func rawTime(elapsed: Double) -> Double {
        elapsed * speed
    }

    /// Hold length implied by a release at `releasedAtRawTime`.
    ///
    /// The handoff's "instant" fast-launch mode (its option B): work that
    /// finishes before the clock even reaches the hold point skips the hold
    /// entirely, so launch time tracks real loading time. A release DURING
    /// the hold still completes the current breath — never exits mid-pulse.
    public static func holdLength(releasedAtRawTime: Double) -> Double {
        guard releasedAtRawTime > holdStart else { return 0 }
        let held = releasedAtRawTime - holdStart
        // Tiny epsilon so a release landing exactly on a cycle boundary
        // doesn't buy a whole extra breath to floating-point noise.
        return (held / breathLength - 1e-9).rounded(.up) * breathLength
    }

    /// Story time + hold-loop phase for `elapsed` real seconds.
    /// `releasedAtRawTime` is `rawTime(elapsed:)` captured when background
    /// work finished — nil while it's still pending (the hold loops forever).
    public static func position(
        elapsed: Double,
        releasedAtRawTime: Double?
    ) -> (storyTime: Double, holdPhase: Double?) {
        let r = rawTime(elapsed: elapsed)
        if r <= holdStart { return (r, nil) }
        let hold = releasedAtRawTime.map(holdLength(releasedAtRawTime:))
        if let hold, r > holdStart + hold {
            // Post-hold the story plays at the reveal pace, picking up from
            // the hold point in real time.
            let postHoldElapsed = elapsed - introRealLength - hold / speed
            return (min(holdStart + postHoldElapsed * revealSpeed, activeEnd), nil)
        }
        let phase = ((r - holdStart).truncatingRemainder(dividingBy: breathLength)) / breathLength
        return (holdStart, phase)
    }

    /// True once the story has fully played out (release happened and the
    /// resumed clock passed `activeEnd`) — the stage can be torn down.
    public static func isComplete(elapsed: Double, releasedAtRawTime: Double?) -> Bool {
        guard let releasedAtRawTime else { return false }
        let hold = holdLength(releasedAtRawTime: releasedAtRawTime)
        let revealRealLength = (activeEnd - holdStart) / revealSpeed
        return elapsed >= introRealLength + hold / speed + revealRealLength
    }
}
