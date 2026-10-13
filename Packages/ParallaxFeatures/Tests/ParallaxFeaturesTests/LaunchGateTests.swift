import Testing
import Foundation
import ParallaxCore
import ParallaxCoreTestSupport
import ParallaxFeatures

@MainActor
struct LaunchGateTests {
    /// A launch with cached content (or an SMB-only setup) has nothing to cover, so its
    /// gate is born finished: no stage ever mounts, content is simply there.
    @Test("the caller decides at init whether a story plays at all")
    func playsStoryIsChosenAtInit() {
        #expect(!LaunchGate(clock: TestClock()).isFinished)
        #expect(LaunchGate(playsStory: false, clock: TestClock()).isFinished)
    }

    /// Reaching Home for the first time after a sign-in IS a first run — there was no cached
    /// content when the process started — so a launch that skipped the story must still be
    /// able to play it there. Born-finished is exactly the state `rearm()` revives from.
    @Test("rearm() revives the full story on a launch that skipped it")
    func rearmRevivesSkippedStory() {
        let gate = LaunchGate(playsStory: false, clock: TestClock())
        gate.rearm()

        #expect(!gate.isFinished)
        #expect(gate.releasedAtRawTime == nil)
        #expect(!gate.stageBegan)
    }

    /// `rearm()` is a no-op unless a prior launch already finished, so it can't restart a
    /// reveal that's mid-play.
    @Test("rearm() leaves a story that is still playing alone")
    func rearmIgnoresAPlayingStory() {
        let gate = LaunchGate(clock: TestClock())
        gate.beginStage()
        gate.rearm()
        #expect(gate.stageBegan)
    }

    /// Content readiness is a fact about the app, not about whether a stage is up — the
    /// call sites stay unconditional, and a finished gate just ignores it.
    @Test("markContentReady() is a no-op on a launch born finished")
    func markContentReadyIsHarmlessWhenSkipped() {
        let gate = LaunchGate(playsStory: false, clock: TestClock())
        gate.markContentReady()
        #expect(gate.releasedAtRawTime == nil)
        #expect(gate.isFinished)
    }

    /// The stage clock's zero is the first RENDERED frame, not process init — boot time
    /// must not eat the animation's opening. Only the first appearance per arm anchors.
    @Test("beginStage() anchors the clock once per arm")
    func beginStageAnchorsOnce() {
        let clock = TestClock()
        let gate = LaunchGate(clock: clock)
        #expect(!gate.stageBegan)

        clock.advance(by: .seconds(2))   // boot, before the first frame
        gate.beginStage()
        #expect(gate.stageBegan)
        clock.advance(by: .seconds(1))
        gate.beginStage()                // a later appearance moves nothing
        clock.advance(by: .seconds(2))
        gate.markContentReady()

        #expect(gate.releasedAtRawTime == LaunchClock.rawTime(elapsed: 3))
    }

    /// Content that's ready before the stage has rendered a frame (cache hydration beating
    /// boot) is a release at raw time 0 — pre-intro, hold skipped — NOT a release measured
    /// against a zero that `beginStage()` is still going to move.
    @Test("a release before the stage began pins to raw time 0")
    func preStageReleaseIsRawZero() {
        let gate = LaunchGate(clock: TestClock())
        gate.markContentReady()
        #expect(gate.releasedAtRawTime == 0)
    }

    @Test("rearm() re-arms the stage anchor")
    func rearmResetsAnchor() {
        let gate = LaunchGate(clock: TestClock())
        gate.beginStage()
        gate.finish()
        gate.rearm()
        #expect(!gate.stageBegan)
    }
}
