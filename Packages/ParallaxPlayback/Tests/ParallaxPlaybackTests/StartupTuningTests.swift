import AVFoundation
import Testing
import ParallaxTestScaling
@testable import ParallaxPlayback

@Suite("StartupTuning")
@MainActor
struct StartupTuningTests {
    /// An `AVPlayerItem` never asked to load network data — enough to read/write its
    /// `preferredForwardBufferDuration`, which is all `applyTuning` touches.
    private func makeItem() -> AVPlayerItem {
        AVPlayerItem(asset: AVURLAsset(url: URL(string: "https://example.invalid/video.mp4")!))
    }

    /// `nil` means "leave the property alone", NOT "write the documented default" — the
    /// distinction the type doc calls out, because touching a property at all pins
    /// behavior against a future OS default change.
    @Test(".systemDefault carries no knobs and leaves the item untouched")
    func systemDefaultAppliesNothing() {
        #expect(StartupTuning.systemDefault.preferredForwardBufferSeconds == nil)

        let item = makeItem()
        let before = item.preferredForwardBufferDuration
        AVKitEngine.applyTuning(.systemDefault, to: item)
        #expect(item.preferredForwardBufferDuration == before)
    }

    /// 0 is a *meaningful* value ("let AVFoundation choose per-item"), distinct from nil,
    /// so it must be written through rather than treated as absent.
    @Test("an explicit forward-buffer target is written onto the item",
          arguments: [0.0, 1.0, 3.0, 12.5] as [Double])
    func explicitTuningApplies(seconds: Double) {
        let item = makeItem()
        AVKitEngine.applyTuning(
            StartupTuning(preferredForwardBufferSeconds: seconds),
            to: item
        )
        #expect(item.preferredForwardBufferDuration == seconds)
    }
}

/// The forward-buffer target is a startup knob: it buys the first frame sooner. Left on for the
/// session, AVPlayer keeps only that much ahead of the playhead, and the progress bar's buffered
/// layer shrinks back onto the dot between segments.
@Suite("StartupTuning — after startup", .serialized, .scaledTimeLimit())
@MainActor
struct StartupTuningReleaseTests {
    @Test("once playback starts, the buffer runs past the startup target")
    func bufferRunsAheadOnceStarted() async throws {
        let server = try HLSLoopbackServer.serving(
            directory: AVKitFixtures.longGOPStream, withholding: [], until: ResponseGate()
        )
        defer { server.stop() }
        let engine = AVKitEngine(tuning: StartupTuning(preferredForwardBufferSeconds: 3))
        try await engine.load(.fixture(url: try await server.baseURL().appending(path: "main.m3u8")))
        await engine.play()

        // 13 s segments: under a 3 s target the buffer holds at a segment's end until the
        // playhead nears it, so a 40 s buffer this early means the target let go.
        let ahead = await engine.firstBeat(within: CITimeScale.seconds(6)) { beat in
            guard case .playing(let position, _, let buffered?, _) = beat.state else { return false }
            return CMTimeGetSeconds(buffered) >= 39 && CMTimeGetSeconds(position) < 13
        }
        #expect(ahead != nil, "the buffer never ran past the startup target")
        await engine.teardown()
    }
}
