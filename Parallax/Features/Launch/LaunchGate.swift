import Foundation
import Observation
import ParallaxCore

/// One-shot, per-process state for the launch animation. The stage plays over
/// the real root content from process start; `markContentReady()` releases the
/// sync-hold once the first screen's data is in hand (Home loaded/failed, or
/// the login destination resolved); `finish()` tears the stage down after the
/// iris reveal completes. Server switches and in-session reloads never re-arm
/// it — those keep the inline skeletons.
@Observable
@MainActor
final class LaunchGate {
    /// The story clock's zero — the moment the root view tree first existed.
    let startDate = Date()

    /// Raw story time when launch work finished (`LaunchClock` quantizes the
    /// hold up to a whole breath from this). Nil while work is pending.
    private(set) var releasedAtRawTime: Double?

    /// True once the story played out or was skipped; the host renders
    /// plain content from then on, forever.
    private(set) var isFinished = false

    func markContentReady() {
        guard releasedAtRawTime == nil, !isFinished else { return }
        releasedAtRawTime = LaunchClock.rawTime(elapsed: Date().timeIntervalSince(startDate))
    }

    func finish() {
        isFinished = true
    }
}
