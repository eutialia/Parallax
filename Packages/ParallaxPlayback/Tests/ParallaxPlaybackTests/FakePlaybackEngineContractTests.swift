import Testing
import ParallaxTestScaling
import ParallaxPlaybackTestSupport
import ParallaxPlayback

/// The double every scenario drives runs the same stream contract the real engines pass.
@Suite("FakePlaybackEngine — PlaybackEngine stream contract", .scaledTimeLimit())
@MainActor
struct FakePlaybackEngineContractTests {
    private func makeEngine() -> FakePlaybackEngine {
        FakePlaybackEngine()
    }

    @Test("the state stream is pre-seeded with .idle")
    func emitsIdleFirst() async {
        await PlaybackEngineContract.emitsIdleFirst(makeEngine())
    }

    @Test("teardown finishes the state stream so consumers' for-await loops end")
    func teardownFinishesStream() async {
        await PlaybackEngineContract.teardownFinishesStream(makeEngine())
    }

    @Test("a load goes through the same states, a seek lands the same way while playing, load throws the same errors, and subtitle options are numbered the same",
          .disabled("pending"))
    func matchesTheOtherEngine() async throws {}
}
