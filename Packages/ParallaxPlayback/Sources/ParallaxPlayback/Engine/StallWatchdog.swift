import Foundation

/// Bounds a *mid-playback* stall, the sibling of `LoadWatchdog` (which bounds the *load*). Without
/// it, a network death after the first frame strands the player forever on the buffering scrim:
/// AVKit sits in `.waitingToPlayAtSpecifiedRate` retrying a dead socket with no timeout, and VLC's
/// `player.isPlaying` reflects intent (not frames) so its poll keeps emitting `.playing` over a
/// frozen clock. The receiving end has always existed — `PlaybackError.networkStalled` maps to the
/// "The stream stalled and didn't recover…" copy — but nothing ever emitted it. This is that emitter.
///
/// Usage: `arm()` on the first `.buffering` beat (a mid-stream stall — network underrun, seek past
/// the buffer); re-`arm()` on further `.buffering` (idempotent reset of the clock); `disarm()` on any
/// transport beat (`.playing`/`.paused`), terminal state, or teardown. If neither a transport beat nor
/// a disarm arrives within `deadline`, `onExpiry` fires once on the MainActor — the engine yields
/// `.failed(.networkStalled)` so the error scrim + manual retry take over instead of an eternal spinner.
///
/// No SwiftUI/Combine (package rule): a bare `Task` + `Duration`, `@MainActor` because the engines are
/// and `onExpiry` mutates engine state. Shape mirrors `LoadWatchdog`; unlike it, `onExpiry` is bound at
/// `init` (the wiring calls bare `arm()`/`disarm()` from several transport sites without re-passing it).
@MainActor
final class StallWatchdog {
    private var task: Task<Void, Never>?
    private let deadline: Duration
    private let onExpiry: @MainActor () -> Void

    /// 45s default — the single source both engines share (each constructs `StallWatchdog { … }` with
    /// the default). Longer than `LoadWatchdog`'s 30s first-frame budget: a mid-stream stall gets more
    /// patience because a transient LAN/NAS hiccup or a Jellyfin transcode catching up can legitimately
    /// pause frames for tens of seconds before recovering on its own, and a false failure mid-movie is
    /// more disruptive than one at load. Wants a slow-network device pass.
    init(deadline: Duration = .seconds(45), onExpiry: @escaping @MainActor () -> Void) {
        self.deadline = deadline
        self.onExpiry = onExpiry
    }

    /// Start (or restart) the deadline. Idempotent: a prior armed timer is superseded so only the
    /// latest fires — re-arming on each `.buffering` beat resets the clock.
    func arm() {
        task?.cancel()
        task = Task { [deadline, onExpiry] in
            try? await Task.sleep(for: deadline)
            guard !Task.isCancelled else { return }
            onExpiry()
        }
    }

    /// Cancel the pending deadline (a transport beat cleared the stall, or teardown). Idempotent.
    func disarm() {
        task?.cancel()
        task = nil
    }
}
