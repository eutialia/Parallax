import Testing
import Foundation
import ParallaxCore
import ParallaxJellyfin
@testable import Parallax

@MainActor
struct LaunchGateTests {
    /// A launch with cached content (or an SMB-only setup) has nothing to cover, so its
    /// gate is born finished: no stage ever mounts, content is simply there.
    @Test("the caller decides at init whether a story plays at all")
    func playsStoryIsChosenAtInit() {
        #expect(!LaunchGate().isFinished)
        #expect(LaunchGate(playsStory: false).isFinished)
    }

    /// Reaching Home for the first time after a sign-in IS a first run — there was no cached
    /// content when the process started — so a launch that skipped the story must still be
    /// able to play it there. Born-finished is exactly the state `rearm()` revives from.
    @Test("rearm() revives the full story on a launch that skipped it")
    func rearmRevivesSkippedStory() {
        let gate = LaunchGate(playsStory: false)
        gate.rearm()

        #expect(!gate.isFinished)
        #expect(gate.releasedAtRawTime == nil)
        #expect(!gate.stageBegan)
    }

    /// `rearm()` is a no-op unless a prior launch already finished, so it can't restart a
    /// reveal that's mid-play.
    @Test("rearm() leaves a story that is still playing alone")
    func rearmIgnoresAPlayingStory() {
        let gate = LaunchGate()
        gate.beginStage()
        gate.rearm()
        #expect(gate.stageBegan)
    }

    /// Content readiness is a fact about the app, not about whether a stage is up — the
    /// call sites stay unconditional, and a finished gate just ignores it.
    @Test("markContentReady() is a no-op on a launch born finished")
    func markContentReadyIsHarmlessWhenSkipped() {
        let gate = LaunchGate(playsStory: false)
        gate.markContentReady()
        #expect(gate.releasedAtRawTime == nil)
        #expect(gate.isFinished)
    }

    /// The stage clock's zero is the first RENDERED frame, not process init — boot time
    /// must not eat the animation's opening. Only the first appearance per arm anchors.
    @Test("beginStage() anchors the clock once per arm")
    func beginStageAnchorsOnce() async throws {
        let gate = LaunchGate()
        let initDate = gate.startDate
        #expect(!gate.stageBegan)

        try await Task.sleep(for: .milliseconds(20))
        gate.beginStage()
        let anchored = gate.startDate
        #expect(gate.stageBegan)
        #expect(anchored > initDate)

        gate.beginStage()
        #expect(gate.startDate == anchored)
    }

    /// Content that's ready before the stage has rendered a frame (cache hydration beating
    /// boot) is a release at raw time 0 — pre-intro, hold skipped — NOT a release measured
    /// against a zero that `beginStage()` is still going to move.
    @Test("a release before the stage began pins to raw time 0")
    func preStageReleaseIsRawZero() {
        let gate = LaunchGate()
        gate.markContentReady()
        #expect(gate.releasedAtRawTime == 0)
    }

    @Test("rearm() re-arms the stage anchor")
    func rearmResetsAnchor() {
        let gate = LaunchGate()
        gate.beginStage()
        gate.finish()
        gate.rearm()
        #expect(!gate.stageBegan)
    }
}
