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
public final class LaunchGate {

    /// The stage clock's zero — the overlay's FIRST RENDERED FRAME, not process
    /// start. Boot (init → first frame) costs hundreds of ms; anchoring at init
    /// silently consumed that much of the animation, so the user only ever saw
    /// its tail — on a 0.4s micro-reveal, most of it. The launch screen's field
    /// color covers the gap, so a first-frame zero is seamless.
    public private(set) var startDate: Date

    /// Whether the overlay has anchored the clock since the last (re)arm.
    public private(set) var stageBegan = false

    /// Raw story time when launch work finished (`LaunchClock` quantizes the
    /// hold up to a whole breath from this). Nil while work is pending.
    public private(set) var releasedAtRawTime: Double?

    /// True once the story played out or was skipped; the host renders
    /// plain content from then on (until a `rearm()`).
    public private(set) var isFinished = false

    /// How long the hold may last before the gate releases it itself.
    static let holdTimeout: Duration = .seconds(15)

    private let now: () -> Date
    private var armEpoch = 0

    /// The story is a first-impression piece — it earns its ~2.6s by covering a
    /// boot the user would otherwise watch. A launch with cached content to show
    /// (or an SMB-only setup with no bootstrap at all) has nothing to cover, so
    /// it's born finished: content appears immediately, no stage, no reveal.
    /// `rearm()` still revives the full story for the post-sign-in moment.
    public init(playsStory: Bool = true, now: @escaping () -> Date = Date.init) {
        self.now = now
        startDate = now()
        isFinished = !playsStory
    }

    /// Anchors the clock at the overlay's first appearance. Idempotent per arm:
    /// only the first frame after an (re)arm moves the zero.
    public func beginStage() {
        guard !stageBegan else { return }
        stageBegan = true
        startDate = now()
    }

    /// Releases the sync-hold. A no-op on a launch born finished (nothing is
    /// holding), but the call sites stay unconditional: "content is ready" is a
    /// fact about the app, not about whether a stage is up.
    public func markContentReady() {
        guard releasedAtRawTime == nil, !isFinished else { return }
        // Ready before the stage even rendered (cache hydration beating the
        // first frame): that's a release at raw time 0 — pre-intro, so the
        // hold is skipped. Computing against `startDate` here would pin the
        // release to a zero that `beginStage()` is still going to move.
        releasedAtRawTime = stageBegan
            ? LaunchClock.rawTime(elapsed: now().timeIntervalSince(startDate))
            : 0
    }

    /// Failsafe: the hold is designed to loop until `markContentReady()`, but a release path that
    /// never fires (hung bootstrap, a future router destination nobody wired up) must not leave an
    /// input-blocking overlay up forever. Generous on purpose: real loads release long before this.
    /// The timer runs from the stage's first frame; each (re)arm gets its own, and a hold that settles or is torn down drops it.
    func releaseStuckHold(on clock: any Clock<Duration>) async {
        var timer: Task<Void, Never>?
        for await pending in Observations({ self.pendingHold }) {
            timer?.cancel()
            timer = pending.map { _ in
                Task {
                    guard (try? await clock.sleep(for: Self.holdTimeout)) != nil else { return }
                    self.markContentReady()
                }
            }
        }
        timer?.cancel()
        await timer?.value
    }

    /// The arm whose hold is on screen and still waiting for content; nil before the stage's first
    /// frame, and once released or finished.
    private var pendingHold: Int? {
        stageBegan && !isFinished && releasedAtRawTime == nil ? armEpoch : nil
    }

    public func finish() {
        isFinished = true
    }

    /// Replay the reveal from frame 0 over the next content. Called when the
    /// FIRST Home is reached after a logged-out launch (sign-in): the cold-launch
    /// reveal was skipped for want of a server, so it plays now, over the booting
    /// Home. No-op unless a prior story already finished (so it can't restart a
    /// reveal that's mid-play, and a server switch — which never finished — stays
    /// skeleton-only).
    ///
    /// Always the FULL story, whatever this process launched with — reaching Home
    /// for the first time after a sign-in IS a first run: there was no cached
    /// content when the process started, and the Home behind this reveal is
    /// genuinely booting from nothing.
    public func rearm() {
        guard isFinished else { return }
        armEpoch += 1
        startDate = now()
        stageBegan = false
        releasedAtRawTime = nil
        isFinished = false
    }
}
