import Foundation
import Observation
import ParallaxCore

/// Per-process state for the launch animation. The stage plays over the real
/// root content to cover the first Home's boot+fetch; `markContentReady()`
/// releases the sync-hold once that data is in hand (Home loaded/failed);
/// `finish()` tears the stage down after the iris reveal completes.
///
/// The reveal is tied to entering Home, NOT to process start: a serverless cold
/// launch lands on login with nothing to reveal, so the stage is `finish()`-ed
/// straight away (no story behind the sign-in sheet) and `rearm()`-ed when a
/// server is finally added (login → Home), so the reveal plays over THAT boot.
/// Server switches and in-session reloads never re-arm it — those keep the
/// inline skeletons.
@Observable
@MainActor
final class LaunchGate {
    /// The story clock's zero — the moment the stage (re)armed. A `var` (not the
    /// process-start constant it looks like) so `rearm()` can replay the reveal
    /// from frame 0 when the first Home is reached after a logged-out start.
    private(set) var startDate = Date()

    /// Raw story time when launch work finished (`LaunchClock` quantizes the
    /// hold up to a whole breath from this). Nil while work is pending.
    private(set) var releasedAtRawTime: Double?

    /// True once the story played out or was skipped; the host renders
    /// plain content from then on (until a `rearm()`).
    private(set) var isFinished = false

    func markContentReady() {
        guard releasedAtRawTime == nil, !isFinished else { return }
        releasedAtRawTime = LaunchClock.rawTime(elapsed: Date().timeIntervalSince(startDate))
    }

    func finish() {
        isFinished = true
    }

    /// Replay the reveal from frame 0 over the next content. Called when the
    /// FIRST Home is reached after a logged-out launch (sign-in): the cold-launch
    /// reveal was skipped for want of a server, so it plays now, over the booting
    /// Home. No-op unless a prior story already finished (so it can't restart a
    /// reveal that's mid-play, and a server switch — which never finished — stays
    /// skeleton-only).
    func rearm() {
        guard isFinished else { return }
        startDate = Date()
        releasedAtRawTime = nil
        isFinished = false
    }
}
