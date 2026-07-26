import Foundation
import CoreMedia
import Testing
import ParallaxPlayback

/// A `PlaybackEngine` implementing ONLY the required members, so the protocol's default
/// implementations are the ones under test. Deliberately not `FakePlaybackEngine`: that
/// double overrides `isBuffered` and `setSubtitleDelay`, which is exactly what would
/// hide a broken default here.
private final class BarePlaybackEngine: PlaybackEngine {
    nonisolated let id: PlaybackEngineID = .avKit
    nonisolated let capabilities = PlaybackEngineCapabilities(
        supportsPiP: false, supportsVideoAirPlay: false, supportsNowPlayingIntegration: false
    )
    nonisolated let state: AsyncStream<PlaybackState>
    private let continuation: AsyncStream<PlaybackState>.Continuation

    init() {
        let (stream, cont) = AsyncStream<PlaybackState>.makeStream()
        self.state = stream
        self.continuation = cont
    }

    func load(_ asset: PlayableAsset) async throws {}
    func play() async {}
    func pause() async {}
    func seek(to time: CMTime) async {}
    func setAudioTrack(_ track: AudioTrack) async {}
    func setSubtitleTrack(_ track: SubtitleTrack?) async {}
    func teardown() async { continuation.finish() }
}

/// These defaults are what makes the protocol implementable by an engine that has no
/// clock, no buffer query, no telemetry and no subtitle/rate control — and each one has
/// a caller that reads it, so a wrong default is a live bug, not dead code.
@Suite("PlaybackEngine protocol defaults")
struct PlaybackEngineDefaultsTests {

    @Test("currentTime defaults to zero, so the subtitle overlay starts at 0:00 rather than an invalid clock")
    func currentTimeDefault() {
        #expect(BarePlaybackEngine().currentTime == .zero)
    }

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

    /// The HUD renders "—" for every absent field, so the default snapshot has to be the
    /// empty one rather than a partially-filled guess.
    @Test("debugSnapshot defaults to the empty snapshot")
    func debugSnapshotDefault() async {
        let snapshot = await BarePlaybackEngine().debugSnapshot()
        #expect(snapshot == .empty)
    }

    /// AVKit has no subtitle-retiming or rate API; the defaults must absorb those calls
    /// silently so the player's controls don't need to branch per engine.
    @Test("setSubtitleDelay and setRate default to inert no-ops")
    func inertDefaults() async {
        let engine = BarePlaybackEngine()
        await engine.setSubtitleDelay(milliseconds: 250)
        await engine.setRate(2.0)
        #expect(engine.currentTime == .zero)
        let snapshot = await engine.debugSnapshot()
        #expect(snapshot == .empty)
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
        #expect(info.audibleOptions.isEmpty)
        #expect(info.legibleOptions.isEmpty)
        #expect(info.errorLogTail.isEmpty)
    }

    /// The HUD polls this and diffs snapshots; a snapshot carrying one populated field
    /// must not compare equal to the empty one.
    @Test("a populated snapshot is distinguishable from the empty one")
    func populatedIsNotEmpty() {
        var info = PlaybackDebugInfo.empty
        info.transportState = "waiting (minimize stalls)"
        #expect(info != .empty)
        #expect(PlaybackDebugInfo.empty == PlaybackDebugInfo())
    }

    /// "selected but doesn't render" is the wedge the HUD exists to expose: options
    /// listed, nothing selected. The type must be able to represent it.
    @Test("options can be listed with nothing selected")
    func representsTheUnselectedWedge() {
        let info = PlaybackDebugInfo(
            legibleOptions: ["English", "French"],
            selectedLegible: nil
        )
        #expect(info.legibleOptions.count == 2)
        #expect(info.selectedLegible == nil)
    }
}
