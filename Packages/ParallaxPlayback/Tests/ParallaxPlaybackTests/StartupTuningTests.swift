import AVFoundation
import Testing
import ParallaxCoreTestSupport
@testable import ParallaxPlayback

/// What a tuning profile does to the item the engine loads, before it plays.
@Suite("StartupTuning — the loaded item", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct StartupTuningLoadTests {
    @Test(".systemDefault leaves the loaded item's forward buffer at AVFoundation's own")
    func systemDefaultLeavesTheItemAlone() async throws {
        let engine = AVKitEngine(tuning: .systemDefault, clock: TestClock())
        try await engine.load(.fixture(url: AVKitFixtures.tiny))
        let item = try #require(engine.avPlayer.currentItem)
        #expect(item.preferredForwardBufferDuration == AVPlayerItem(url: try AVKitFixtures.tiny).preferredForwardBufferDuration)
        await engine.teardown()
    }

    /// 0 is meaningful ("let AVFoundation choose per item"), not absent.
    @Test("an explicit forward-buffer target is on the loaded item", arguments: [0.0, 1.0, 3.0, 12.5] as [Double])
    func explicitTargetIsOnTheItem(seconds: Double) async throws {
        let engine = AVKitEngine(tuning: StartupTuning(preferredForwardBufferSeconds: seconds), clock: TestClock())
        try await engine.load(.fixture(url: AVKitFixtures.tiny))
        #expect(engine.avPlayer.currentItem?.preferredForwardBufferDuration == seconds)
        await engine.teardown()
    }
}

/// The forward-buffer target is a startup knob: it buys the first frame sooner. Left on for the
/// session, AVPlayer keeps only that much ahead of the playhead, and the progress bar's buffered
/// layer shrinks back onto the dot between segments.
@Suite("StartupTuning — after startup", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct StartupTuningReleaseTests {
    @Test("once playback starts, the buffer runs past the startup target")
    func bufferRunsAheadOnceStarted() async throws {
        let server = try HLSLoopbackServer.serving(
            directory: AVKitFixtures.longGOPStream, withholding: [], until: ResponseGate()
        )
        defer { server.stop() }
        let engine = AVKitEngine(tuning: StartupTuning(preferredForwardBufferSeconds: 3), clock: TestClock())
        try await engine.load(.fixture(url: try await server.baseURL().appending(path: "main.m3u8")))
        await engine.play()

        // 13 s segments: under a 3 s target the buffer holds at a segment's end until the
        // playhead nears it, so a 40 s buffer this early means the target let go.
        let ahead = await engine.firstBeat(within: .seconds(6)) { beat in
            guard case .playing(let position, _, let buffered?, _) = beat.state else { return false }
            return CMTimeGetSeconds(buffered) >= 39 && CMTimeGetSeconds(position) < 13
        }
        #expect(ahead != nil, "the buffer never ran past the startup target")
        await engine.teardown()
    }
}
