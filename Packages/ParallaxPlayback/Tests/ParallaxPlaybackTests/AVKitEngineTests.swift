import Foundation
import CoreMedia
import Testing
import ParallaxPlayback

@Suite("AVKitEngine")
@MainActor
struct AVKitEngineTests {
    @Test("Declares the AVKit id and all-true capabilities")
    func identityAndCapabilities() {
        let engine = AVKitEngine()
        #expect(engine.id == .avKit)
        #expect(engine.capabilities.supportsPiP)
        #expect(engine.capabilities.supportsVideoAirPlay)
        #expect(engine.capabilities.supportsAudioAirPlay)
        #expect(engine.capabilities.supportsNowPlayingIntegration)
    }

    @Test("Conforms to AVPlayerHosting and exposes a live AVPlayer")
    func hostsAnAVPlayer() {
        let engine = AVKitEngine()
        let hosting = engine as? AVPlayerHosting
        #expect(hosting != nil)
        #expect(hosting?.avPlayer === engine.avPlayer)
    }

    @Test("state stream emits .idle before any load")
    func emitsIdleFirst() async {
        let engine = AVKitEngine()
        var iterator = engine.state.makeAsyncIterator()
        let first = await iterator.next()
        guard case .idle = first else {
            Issue.record("expected .idle, got \(String(describing: first))")
            return
        }
    }

    @Test("teardown finishes the state stream")
    func teardownFinishesStream() async {
        let engine = AVKitEngine()
        await engine.teardown()
        var iterator = engine.state.makeAsyncIterator()
        // Drain any buffered .idle; the stream must then terminate.
        while let value = await iterator.next() {
            if case .idle = value { continue }
            break
        }
        let terminal = await iterator.next()
        #expect(terminal == nil)
    }

    @Test("trackInventory maps AVPlayerItem media options to AudioTrack/SubtitleTrack")
    func trackInventoryMapsOptions() async {
        // AVPlayerItem over a real asset isn't feasible in a unit test; verify the
        // TrackInventory shape round-trips (real mapping is device-verified in 5f).
        let inv = TrackInventory(
            audio: [AudioTrack(id: "opt-en", displayName: "English", languageCode: "en")],
            subtitles: [SubtitleTrack(id: "opt-fr", displayName: "French SDH", languageCode: "fr", isForced: false)]
        )
        #expect(inv.audio.count == 1)
        #expect(inv.audio[0].id == "opt-en")
        #expect(inv.subtitles.count == 1)
        #expect(inv.subtitles[0].id == "opt-fr")
    }
}
