import Testing
import ParallaxPlaybackTestSupport
import ParallaxPlayback

/// The double every scenario drives runs the same stream contract the real engines pass.
@Suite("FakePlaybackEngine — PlaybackEngine stream contract", .timeLimit(.minutes(1)))
@MainActor
struct FakePlaybackEngineContractTests {
    private func makeEngine() -> FakePlaybackEngine {
        FakePlaybackEngine(id: .avKit, capabilities: .avKit)
    }

    @Test("the state stream is pre-seeded with .idle")
    func emitsIdleFirst() async {
        await PlaybackEngineContract.emitsIdleFirst(makeEngine())
    }

    @Test("teardown finishes the state stream so consumers' for-await loops end")
    func teardownFinishesStream() async {
        await PlaybackEngineContract.teardownFinishesStream(makeEngine())
    }

    @Test("the engine reports the id and capabilities it was built with")
    func identity() {
        PlaybackEngineContract.identity(makeEngine(), id: .avKit, capabilities: .avKit)
    }
}
