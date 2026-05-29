import Foundation
import CoreMedia
import Testing
@testable import ParallaxPlayback

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
}
