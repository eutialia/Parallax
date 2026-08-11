import Foundation
import CoreMedia

/// The engine abstraction. Single-consumer `state` stream — `PlayerViewModel`
/// is the sole reader. Both `AVKitEngine` (Phase 4) and `VLCKitEngine` (Phase 5)
/// conform. All `async` methods are witnessed by `@MainActor` methods on concrete
/// engines; the `nonisolated` synchronous requirements use `nonisolated let` storage.
public protocol PlaybackEngine: AnyObject, Sendable {
    /// Stable identifier for the engine type.
    nonisolated var id: PlaybackEngineID { get }

    /// Static capabilities that do not change at runtime.
    nonisolated var capabilities: PlaybackEngineCapabilities { get }

    /// The live playback clock, smooth enough for sub-second cue timing (the `state`
    /// stream's ~0.5s beats are too coarse). Read directly by the client-side subtitle
    /// overlay so it can sync cues against any engine. `.zero` when nothing is loaded.
    nonisolated var currentTime: CMTime { get }

    /// Single-consumer state stream. Only `PlayerViewModel` iterates this.
    /// Terminal delivery is NOT idempotent at the engine layer: an engine may
    /// emit `.ended`, and `teardown()` separately finishes the continuation, so
    /// the consumer must de-duplicate terminal reporting (e.g. a natural
    /// `.ended` followed by a teardown on dismissal). A future engine is free to
    /// strengthen this to a single terminal event; until then the guard lives in
    /// the view model.
    nonisolated var state: AsyncStream<PlaybackState> { get }

    /// Load the asset. Seeks to `asset.startTime` when the item becomes ready.
    /// Throws `PlaybackError` if the item cannot be prepared.
    func load(_ asset: PlayableAsset) async throws

    /// Begin or resume playback.
    func play() async

    /// Pause playback.
    func pause() async

    /// Silence audio output NOW, ahead of a deferred teardown. Dismissal keeps the
    /// engine alive for the whole close animation (the last frame rides the card out),
    /// so audio needs a kill switch that does not wait for `teardown()`. Best-effort;
    /// the next `play()` restores audio.
    func silence() async

    /// Seek to an arbitrary position. No-op if no item is loaded.
    func seek(to time: CMTime) async

    /// Whether `time` lies within the engine's buffered media, so a seek there
    /// completes without a server fetch. The transcode path reads this to choose
    /// between an in-stream seek (in-buffer: instant, stays on the current aligned
    /// session) and a fresh-session re-resolve (out-of-buffer: an in-playlist seek
    /// would restart ffmpeg mid-session, which Jellyfin's `-noaccurate_seek`
    /// misaligns → client subtitle drift, jellyfin#15845).
    func isBuffered(at time: CMTime) async -> Bool

    /// Select an audio track by id. No-op if the id is not in the current inventory.
    func setAudioTrack(_ track: AudioTrack) async

    /// Select a subtitle track by id, or pass nil to disable subtitles.
    func setSubtitleTrack(_ track: SubtitleTrack?) async

    /// Stop playback, remove observers, finish the state stream continuation.
    /// Must be called before releasing the engine.
    func teardown() async

    /// A runtime snapshot for the debug HUD — actual decoded dimensions, network
    /// bitrates, dropped frames, and the engine's *true* audio/subtitle selection.
    /// Polled (not render-bound); reflects "now", not the requested stream.
    func debugSnapshot() async -> PlaybackDebugInfo

    /// Nudge the subtitle timing by `milliseconds` (VLC live-corrects subtitle
    /// sync; AVKit has no such control and ignores it). Positive = subtitles later.
    func setSubtitleDelay(milliseconds: Int) async

    /// Set the playback rate (1.0 = normal). Persisted by the engine so a
    /// later `play()` resumes at the chosen speed.
    func setRate(_ rate: Float) async

    /// Best-effort single-frame capture near the current playback position, for SMB thumbnail
    /// backfill (see `PlayerViewModel` in the app target). Must never throw and must never stall
    /// or otherwise perturb playback — any failure (no active item, decode error, API unsupported
    /// on this engine) returns nil. The returned Data is an already-encoded still image (HEIC or
    /// JPEG — see below), not raw pixels.
    func captureFrame() async -> Data?

    /// Whether `captureFrame()` issues its own fresh I/O to produce the still, as opposed to
    /// reading a frame already resident from ordinary decode. AVKit's `AVAssetImageGenerator`
    /// issues fresh range reads over the SMB bridge reader — contending with the SAME uplink
    /// playback is pulling from; VLC's live snapshot reads no bytes at all, it grabs the frame
    /// already on the decode surface. The app-side backfill (`MediaArtworkProvider`) uses this to
    /// skip the capture on a non-LAN link, where those extra reads can queue ahead of the
    /// player's next chunk and cost a buffer dip for a thumbnail.
    nonisolated var captureFramePerformsIO: Bool { get }
}

public extension PlaybackEngine {
    /// Default: zero. Real engines override with their live clock.
    nonisolated var currentTime: CMTime { .zero }

    /// Default: always buffered, so the seek goes in-stream. Only an engine whose
    /// buffer can fall behind the seek target (the AVKit HLS transcode) overrides.
    func isBuffered(at time: CMTime) async -> Bool { true }

    /// Default: no debug info. Concrete engines override with real telemetry.
    func debugSnapshot() async -> PlaybackDebugInfo { .empty }

    /// Default: pause. Enough for engines whose pause takes effect on the next render
    /// cycle (AVKit). VLC overrides: its pause is an input-thread command that a blocked
    /// network read can delay for seconds, so it mutes the audio output directly first.
    func silence() async { await pause() }

    /// Default: no-op. Only engines that can retime subtitles (VLC) override.
    func setSubtitleDelay(milliseconds: Int) async {}

    /// Default: no-op. Engines that support variable-speed playback override.
    func setRate(_ rate: Float) async {}

    /// Default: nil. Only engines that can grab a still from the live decode path
    /// (`AVKitEngine`, `VLCKitEngine`) override; a bare / fake engine never pays for a
    /// capture the app-side backfill would just discard.
    func captureFrame() async -> Data? { nil }

    /// Default: true (the conservative assumption — a capture that reads bytes). Symmetric with
    /// `captureFrame()`'s default: an engine that never overrides `captureFrame()` returns nil
    /// from it anyway, so whether this reads true or false there never changes behavior for it.
    nonisolated var captureFramePerformsIO: Bool { true }
}
