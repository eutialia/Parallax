import Foundation
import CoreMedia
import os
import Testing
import ParallaxPlayback

/// A `PlaybackEngine` implementing ONLY the required members, so the protocol's default
/// implementations are the ones under test. Deliberately not `FakePlaybackEngine`: that
/// double overrides `isBuffered`, which is exactly what would hide a broken default here.
private final class BarePlaybackEngine: PlaybackEngine {
    nonisolated let id: PlaybackEngineID = .avKit
    nonisolated let capabilities = PlaybackEngineCapabilities(
        supportsPiP: false, supportsVideoAirPlay: false, supportsNowPlayingIntegration: false
    )
    nonisolated let state: AsyncStream<PlaybackBeat>
    private let continuation: AsyncStream<PlaybackBeat>.Continuation

    init() {
        let (stream, cont) = AsyncStream<PlaybackBeat>.makeStream()
        self.state = stream
        self.continuation = cont
    }

    /// Recorded so the `silence()` default's delegation to `pause()` is observable.
    /// Recording inside a REQUIRED member keeps the "no overridden defaults" rule intact.
    /// Locked because `PlaybackEngine` is `Sendable`.
    private let pauseCalls = OSAllocatedUnfairLock(initialState: 0)
    var pauseCallCount: Int { pauseCalls.withLock { $0 } }

    func load(_ asset: PlayableAsset) async throws -> PlaybackSessionID { .none.next() }
    func play() async {}
    func pause() async { pauseCalls.withLock { $0 += 1 } }
    func seek(to time: CMTime) async {}
    func setAudioTrack(_ track: AudioTrack) async {}
    func setSubtitleTrack(_ track: SubtitleTrack?) async {}
    func teardown() async { continuation.finish() }
}

/// These defaults are what makes the protocol implementable by an engine that has no
/// buffer query and no render-level silence — and each one has a caller that reads it,
/// so a wrong default is a live bug, not dead code.
@Suite("PlaybackEngine protocol defaults")
struct PlaybackEngineDefaultsTests {

    /// Default "always buffered" means the transcode seek path takes the in-stream
    /// branch. Only the AVKit HLS engine — whose buffer can genuinely fall behind the
    /// seek target — overrides it; every other engine must NOT trigger a re-resolve.
    @Test("isBuffered defaults to true for every position", arguments: [
        CMTime.zero,
        CMTime(seconds: 60, preferredTimescale: 1000),
        CMTime(seconds: 100_000, preferredTimescale: 1000),
    ])
    func isBufferedDefault(time: CMTime) async {
        let buffered = await BarePlaybackEngine().isBuffered(at: time)
        #expect(buffered)
    }

    /// AVKit relies on this default: only the VLC engine overrides `silence()` with a
    /// render-level mute. If the default stopped pausing, closing an AVKit player would
    /// leave audio running behind the dismissed UI.
    @Test("silence defaults to delegating to pause")
    func silenceDefaultDelegatesToPause() async {
        let engine = BarePlaybackEngine()
        await engine.silence()
        #expect(engine.pauseCallCount == 1)
    }

    /// The terminal exit cut. AVKit needs nothing stronger than its resumable silence (its
    /// pause stops the render pipeline on the spot), so the default chains through
    /// `silence()` and, via ITS default, lands on `pause()`. Only VLC overrides, where
    /// mute is a decode-side gain that can't reach already-queued audio.
    @Test("endAudio defaults to delegating to silence, and so to pause")
    func endAudioDefaultDelegatesToSilence() async {
        let engine = BarePlaybackEngine()
        await engine.endAudio()
        #expect(engine.pauseCallCount == 1)
    }

    /// Exit is not always one call: the close button fences the session AND the presenter's
    /// dismissal fences it again. The bare default carries NO latch of its own (VLC's override
    /// is where the terminal one lives), so the second exit is not absorbed: it simply pauses
    /// again. Harmless on an engine whose pause is already the render-level stop, which is why
    /// AVKit needs nothing stronger. Asserted so a latch quietly added here would be caught,
    /// not so repetition is proven inert.
    @Test("endAudio's default carries no latch: a repeated exit just pauses again")
    func endAudioDefaultRepeatsItsPause() async {
        let engine = BarePlaybackEngine()
        await engine.endAudio()
        await engine.endAudio()
        #expect(engine.pauseCallCount == 2)
    }
}

/// `PlaybackDebugInfo.empty` is the value the HUD falls back to whenever an engine can't
/// report — every field must be genuinely absent, or the HUD prints a fabricated number
/// (a zero bitrate reads very differently from "—").
@Suite("PlaybackDebugInfo.empty")
struct PlaybackDebugInfoTests {

    @Test("every optional field is nil")
    func optionalsAreNil() {
        let info = PlaybackDebugInfo.empty
        #expect(info.presentationWidth == nil)
        #expect(info.presentationHeight == nil)
        #expect(info.renderedFrameRate == nil)
        #expect(info.indicatedBitrate == nil)
        #expect(info.observedBitrate == nil)
        #expect(info.droppedVideoFrames == nil)
        #expect(info.bufferedSeconds == nil)
        #expect(info.playheadSeconds == nil)
        #expect(info.itemStatus == nil)
        #expect(info.selectedAudible == nil)
        #expect(info.selectedLegible == nil)
        #expect(info.subtitleDelayMs == nil)
        #expect(info.transportState == nil)
        #expect(info.stallCount == nil)
        #expect(info.bytesTransferred == nil)
    }

    @Test("every list field is empty")
    func listsAreEmpty() {
        let info = PlaybackDebugInfo.empty
        #expect(info.loadedRanges.isEmpty)
        #expect(info.legibleOptions.isEmpty)
        #expect(info.errorLogTail.isEmpty)
        #expect(info.accessLogTail.isEmpty)
    }
}
