import Testing
import ParallaxCoreTestSupport
import ParallaxTestScaling
@testable import ParallaxFeatures

@MainActor
@Suite("Segment prompt one-shot", .scaledTimeLimit())
struct SegmentPromptGateTests {
    /// The playhead's segment, moved by the test the way position beats move it.
    private final class Playhead {
        var segmentID: String?
        init(_ id: String?) { segmentID = id }
    }

    @Test("the button shows for one countdown, then stays down until the playhead leaves the segment")
    func countdownSpendsTheSegment() async throws {
        let clock = TestClock()
        let playhead = Playhead("intro")
        let gate = SegmentPromptGate(clock: clock) { playhead.segmentID }
        #expect(gate.promptVisible(enabled: true))

        let countdown = Task { await gate.runCountdown() }
        try await clock.waitForSleep(dueIn: .seconds(5))
        clock.advance(by: .seconds(5))
        await countdown.value
        #expect(!gate.promptVisible(enabled: true))

        playhead.segmentID = nil
        gate.activeSegmentChanged(to: nil)
        playhead.segmentID = "intro"
        gate.activeSegmentChanged(to: "intro")
        #expect(gate.promptVisible(enabled: true))
    }

    @Test("a countdown cut short by the button hiding spends nothing")
    func cancelledCountdownKeepsTheButton() async throws {
        let clock = TestClock()
        let gate = SegmentPromptGate(clock: clock) { "intro" }

        let countdown = Task { await gate.runCountdown() }
        try await clock.waitForSleep(dueIn: .seconds(5))
        countdown.cancel()
        await countdown.value

        #expect(clock.pendingSleeps == [])
        #expect(gate.promptVisible(enabled: true))
    }

    @Test("a dismissed button shows again when the playhead moves straight into the next segment")
    func nextSegmentShowsAfterExpiry() {
        let playhead = Playhead("recap")
        let gate = SegmentPromptGate(clock: TestClock()) { playhead.segmentID }
        gate.expirePrompt()
        #expect(!gate.promptVisible(enabled: true))

        playhead.segmentID = "intro"
        gate.activeSegmentChanged(to: "intro")
        #expect(gate.promptVisible(enabled: true))
    }
}
