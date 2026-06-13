import Testing
import Foundation
import CoreMedia
import VLCKitSPM
@testable import ParallaxPlayback

@Suite("VLCKitEngine — skeleton")
@MainActor
struct VLCKitEngineTests {

    @Test("id is .vlcKit")
    func engineID() {
        let engine = VLCKitEngine()
        #expect(engine.id == .vlcKit)
    }

    @Test("capabilities: supportsPiP true, supportsVideoAirPlay false, supportsAudioAirPlay true, supportsNowPlayingIntegration true")
    func capabilities() {
        let engine = VLCKitEngine()
        #expect(engine.capabilities.supportsPiP == true)
        #expect(engine.capabilities.supportsVideoAirPlay == false)
        #expect(engine.capabilities.supportsAudioAirPlay == true)
        #expect(engine.capabilities.supportsNowPlayingIntegration == true)
    }

    @Test("conforms to VLCPlayerHosting and exposes a VLCMediaPlayer")
    func vlcPlayerHosting() {
        let engine = VLCKitEngine()
        let hosting = engine as? any VLCPlayerHosting
        #expect(hosting != nil)
    }

    @Test("state stream emits .idle before any load")
    func emitsIdleFirst() async {
        let engine = VLCKitEngine()
        var iterator = engine.state.makeAsyncIterator()
        let first = await iterator.next()
        guard case .idle = first else {
            Issue.record("expected .idle, got \(String(describing: first))")
            return
        }
    }

    @Test("teardown finishes the state stream")
    func teardownFinishesStream() async {
        let engine = VLCKitEngine()
        var iterator = engine.state.makeAsyncIterator()
        _ = await iterator.next()  // drain buffered .idle
        await engine.teardown()
        let terminal = await iterator.next()
        #expect(terminal == nil)
    }

    @Test("seek with non-finite CMTime is a no-op, not a crash")
    func seekInvalidCMTimeDoesNotCrash() async {
        let engine = VLCKitEngine()
        await engine.seek(to: .invalid)      // must not trap
        await engine.seek(to: .indefinite)   // must not trap
    }

    @Test("vlcTimeToCMTime clamps non-positive ms to .zero")
    func vlcTimeToCMTimeClamps() {
        #expect(VLCKitEngine.vlcTimeToCMTime(ms: -1) == .zero)
        #expect(VLCKitEngine.vlcTimeToCMTime(ms: 0) == .zero)
        let t = VLCKitEngine.vlcTimeToCMTime(ms: 2000)
        #expect(CMTimeGetSeconds(t) == 2.0)
    }

    @Test("positionState maps isPlaying to .playing/.paused")
    func positionStateMapping() {
        let playing = VLCKitEngine.positionState(isPlaying: true, positionMs: 1000, durationMs: 4000)
        guard case .playing(let p, let d, _) = playing else {
            Issue.record("expected .playing, got \(playing)"); return
        }
        #expect(CMTimeGetSeconds(p) == 1.0)
        #expect(CMTimeGetSeconds(d) == 4.0)
        let paused = VLCKitEngine.positionState(isPlaying: false, positionMs: 0, durationMs: 0)
        guard case .paused = paused else {
            Issue.record("expected .paused, got \(paused)"); return
        }
    }

    @Test("seekHasSettled: a far transient overshoot is suppressed (forward and backward)")
    func seekTransientSuppressed() {
        // Seek target 480_000ms (08:00). VLC's clock briefly reads 600_000 (10:00).
        #expect(VLCKitEngine.seekHasSettled(now: 600_000, target: 480_000, polls: 1) == false)
        // Backward seek to 05:00 with a transient that overshoots below the target.
        #expect(VLCKitEngine.seekHasSettled(now: 180_000, target: 300_000, polls: 1) == false)
    }

    @Test("seekHasSettled: converges once the clock lands within the keyframe tolerance")
    func seekConvergesWithinTolerance() {
        #expect(VLCKitEngine.seekHasSettled(now: 480_000, target: 480_000, polls: 2))       // exact
        #expect(VLCKitEngine.seekHasSettled(now: 477_500, target: 480_000, polls: 2))       // -2.5s keyframe snap
        #expect(VLCKitEngine.seekHasSettled(now: 482_900, target: 480_000, polls: 2))       // +2.9s keyframe snap
    }

    @Test("seekHasSettled: the fallback budget resumes live tracking even if it never lands exactly")
    func seekFallbackResumes() {
        // Still far off, but the poll budget is spent → resume so the bar can't freeze.
        #expect(VLCKitEngine.seekHasSettled(now: 600_000, target: 480_000, polls: 10))
        #expect(VLCKitEngine.seekHasSettled(now: 600_000, target: 480_000, polls: 9) == false)
    }
}

@Suite("VLCKitEngine — track mapping")
@MainActor
struct VLCKitEngineTrackMappingTests {

    @Test("buildAudioTrack maps trackId, trackName, language")
    func audioTrackMapping() {
        let track = VLCKitEngine.buildAudioTrack(id: "42", name: "English DTS", language: "en")
        #expect(track.id == .vlc("42"))
        #expect(track.displayName == "English DTS")
        #expect(track.languageCode == "en")
    }

    @Test("buildAudioTrack with nil language stores nil")
    func audioTrackNilLanguage() {
        let track = VLCKitEngine.buildAudioTrack(id: "7", name: "Unknown", language: nil)
        #expect(track.languageCode == nil)
    }

    @Test("buildSubtitleTrack maps trackId, trackName, language, forced=false")
    func subtitleTrackMapping() {
        let track = VLCKitEngine.buildSubtitleTrack(id: "s1", name: "French ASS", language: "fr")
        #expect(track.id == .vlc("s1"))
        #expect(track.displayName == "French ASS")
        #expect(track.languageCode == "fr")
        #expect(track.isForced == false)
    }
}

