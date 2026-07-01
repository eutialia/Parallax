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

    @Test("init tightens the time-update cadence so player.time isn't quantized to 1s")
    func fineGrainedTimeUpdates() {
        let engine = VLCKitEngine()
        // VLC defaults `timeChangeUpdateInterval` to 1.0s, quantizing `player.time`: the
        // polled position refreshes once a second, so the scrubber counter skip-jumped +2/s
        // at 2× instead of +1 twice a second. Pin it to 0.25s and drop `minimalTimePeriod`
        // (the 0.5s floor) below it so it can't re-gate the finer interval.
        #expect(engine.vlcPlayer.timeChangeUpdateInterval == 0.25)
        #expect(engine.vlcPlayer.minimalTimePeriod == 100_000)
    }

    @Test("shouldReassertRate: re-applies when the live rate drifted from the chosen speed")
    func reassertRateOnDrift() {
        // The fresh-engine re-apply ran before the input was up → live rate still 1.0× while
        // the user chose 1.5×; and the reverse after dropping back to normal.
        #expect(VLCKitEngine.shouldReassertRate(current: 1.0, desired: 1.5))
        #expect(VLCKitEngine.shouldReassertRate(current: 1.5, desired: 1.0))
    }

    @Test("shouldReassertRate: no redundant write once the live rate matches")
    func noReassertWhenMatched() {
        #expect(VLCKitEngine.shouldReassertRate(current: 1.0, desired: 1.0) == false)
        #expect(VLCKitEngine.shouldReassertRate(current: 2.0, desired: 2.0) == false)
        #expect(VLCKitEngine.shouldReassertRate(current: 1.4999, desired: 1.5) == false)  // float tolerance
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

    @Test("flushBridgeShouldResume: holds while the clock sits at the flush anchor")
    func flushBridgeHolds() {
        // Re-decode in progress: VLC's clock is pinned at the flush point (±jitter), so keep
        // publishing the buffering hold rather than resume to a frozen counter.
        #expect(VLCKitEngine.flushBridgeShouldResume(now: 60_000, anchor: 60_000, ticks: 1) == false)
        #expect(VLCKitEngine.flushBridgeShouldResume(now: 60_150, anchor: 60_000, ticks: 2) == false)  // within +200 jitter
    }

    @Test("flushBridgeShouldResume: resumes once the clock advances past the anchor")
    func flushBridgeResumesOnAdvance() {
        // The re-decode produced output at the new rate and the clock moved on → resume tracking.
        #expect(VLCKitEngine.flushBridgeShouldResume(now: 61_000, anchor: 60_000, ticks: 2))
    }

    @Test("flushBridgeShouldResume: the budget resumes even if the clock never advances")
    func flushBridgeBudgetFallback() {
        // Re-decode never cleanly advanced past the anchor, but the budget is spent → resume so
        // the counter can't hold forever.
        #expect(VLCKitEngine.flushBridgeShouldResume(now: 60_000, anchor: 60_000, ticks: 8))
        #expect(VLCKitEngine.flushBridgeShouldResume(now: 60_000, anchor: 60_000, ticks: 7) == false)
    }

    // MARK: — Unknown / indeterminate duration (incomplete media)

    @Test("vlcDurationToCMTime maps an unresolved length (<= 0) to .indefinite, positive to seconds")
    func vlcDurationToCMTimeUnknown() {
        // libvlc leaves `media.length` at 0 (or the -1 sentinel) when the container's total
        // length isn't in the downloaded bytes — a truncated/incomplete file whose trailing
        // moov atom is missing. That is "unknown duration", NOT 0:00 — represent it with
        // AVFoundation's own sentinel so the app derives one `hasKnownDuration` truth.
        #expect(VLCKitEngine.vlcDurationToCMTime(ms: 0) == .indefinite)
        #expect(VLCKitEngine.vlcDurationToCMTime(ms: -1) == .indefinite)
        let known = VLCKitEngine.vlcDurationToCMTime(ms: 4000)
        #expect(known.isNumeric)
        #expect(CMTimeGetSeconds(known) == 4.0)
    }

    @Test("positionState carries .indefinite duration when the length is unknown, but a real position")
    func positionStateIndefiniteDuration() {
        // Frames are rendering (position is a real clock value) but the length never resolved.
        // The beat must still ship — with an indeterminate duration — so the player leaves
        // `.loading`. Position stays exact; only the duration is unknown.
        let beat = VLCKitEngine.positionState(isPlaying: true, positionMs: 5000, durationMs: 0)
        guard case .playing(let position, let duration, _) = beat else {
            Issue.record("expected .playing, got \(beat)"); return
        }
        #expect(CMTimeGetSeconds(position) == 5.0)
        #expect(duration == .indefinite)
    }

    @Test("liveBeat emits a beat for a live player even when the length is unknown")
    func liveBeatEmitsOnUnknownLength() {
        // THE FIX: the old guard required `durationMs > 0`, so an incomplete file (length
        // unresolvable) never produced a beat and the player wedged in `.loading` forever.
        // Readiness is "frames are rendering" (a valid position), not "duration is known".
        let beat = VLCKitEngine.liveBeat(isPlaying: true, positionMs: 5000, durationMs: 0)
        guard case .playing(let position, let duration, _) = beat else {
            Issue.record("expected a .playing beat, got \(String(describing: beat))"); return
        }
        #expect(CMTimeGetSeconds(position) == 5.0)
        #expect(duration == .indefinite)
    }

    @Test("liveBeat suppresses the pre-first-frame sentinel position to protect the resume point")
    func liveBeatSuppressesSentinelPosition() {
        // `player.time` reads the VLC_TICK_INVALID sentinel (-1) before the first frame.
        // Emitting it would snap `lastPosition` to 0:00 and risk losing the resume point —
        // THAT is the real guard, on POSITION, not on duration.
        #expect(VLCKitEngine.liveBeat(isPlaying: true, positionMs: -1, durationMs: 4000) == nil)
    }

    @Test("estimateDurationMs derives the total from file size ÷ observed DEMUX rate; nil in the early window")
    func estimateDurationFromDemuxRate() {
        // libvlc's `position` is `time / length`, so it's ~0 when the container length never
        // resolves (truncated/incomplete media) — useless here. The length-INDEPENDENT signal is
        // `statistics.demuxReadBytes` (bytes actually consumed by the demuxer — NOT the input
        // `readBytes`, which races ahead with the network read-ahead cache). demux-rate =
        // demuxReadBytes / playedTime, and total = fileSize × playedMs / demuxReadBytes.
        // Real device trace: 297 MB file, 3.05s played, 154 KB demuxed → ~100 min (6_023_873 ms).
        #expect(VLCKitEngine.estimateDurationMs(fileSizeBytes: 311_758_144, playedMs: 3_050, demuxReadBytes: 157_849) == 6_023_873)
        // Early window: below the 3s floor → no estimate yet (indeterminate bar holds).
        #expect(VLCKitEngine.estimateDurationMs(fileSizeBytes: 311_758_144, playedMs: 1_000, demuxReadBytes: 50_000) == nil)
        // Missing inputs → nil (no divide blow-up, no nonsense total).
        #expect(VLCKitEngine.estimateDurationMs(fileSizeBytes: 0, playedMs: 60_000, demuxReadBytes: 157_849) == nil)
        #expect(VLCKitEngine.estimateDurationMs(fileSizeBytes: 311_758_144, playedMs: 60_000, demuxReadBytes: 0) == nil)
        // Degenerate: demuxed more than the whole file (re-reads/seek) → est would be < played → nil.
        #expect(VLCKitEngine.estimateDurationMs(fileSizeBytes: 1_000_000, playedMs: 60_000, demuxReadBytes: 2_000_000) == nil)
    }

    @Test("clampSeekMs floors a rewind-before-zero to 0 so seek() agrees with the positionMs>=0 emit guard")
    func clampSeekMsFloorsNegative() {
        // `seek()` used to clamp its lower bound to Int32.min, admitting a negative ms for a
        // rewind-before-zero scrub. But `liveBeat` suppresses any `positionMs < 0`, so the seek's
        // own optimistic beat vanished AND the poll's `pendingSeekMs` sat at a negative target
        // `player.time` (>= 0) could never reach — freezing live tracking until the 10-poll
        // fallback. Floor to 0 (matching `startMs`) so the engine agrees with its own contract.
        #expect(VLCKitEngine.clampSeekMs(seconds: -5) == 0)
        #expect(VLCKitEngine.clampSeekMs(seconds: 0) == 0)
        #expect(VLCKitEngine.clampSeekMs(seconds: 8) == 8000)
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

