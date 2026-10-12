import Testing
import ParallaxPlaybackTestSupport
import ParallaxPlaybackVLCTestSupport
@testable import ParallaxPlayback
@testable import ParallaxPlaybackVLC

/// The engine-agnostic `PlaybackEngine` stream contract, run against VLCKit. The AVKit half
/// lives in ParallaxPlayback.
// `.timeLimit`: see `PlaybackEngineStreamContractTests` in ParallaxPlayback.
@Suite("VLCKitEngine — stream contract", .timeLimit(.minutes(1)))
@MainActor
struct VLCKitEngineStreamContractTests {

    @Test("the state stream is pre-seeded with .idle")
    func emitsIdleFirst() async {
        await PlaybackEngineContract.emitsIdleFirst(VLCKitEngine())
    }

    @Test("teardown finishes the state stream so consumers' for-await loops end")
    func teardownFinishesStream() async {
        await PlaybackEngineContract.teardownFinishesStream(VLCKitEngine())
    }

    @Test("the engine reports the id and capabilities of the kind that built it")
    func identity() {
        PlaybackEngineContract.identity(VLCKitEngine(), id: .vlcKit, capabilities: .vlcKit)
    }
}
