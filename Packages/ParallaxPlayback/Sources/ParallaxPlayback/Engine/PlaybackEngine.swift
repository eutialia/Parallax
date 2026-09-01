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
    /// Every element carries the session that published it (`PlaybackBeat`) — an engine is
    /// reloadable in place, so the engine's identity alone cannot tell a reload's incoming
    /// beats from the outgoing ones still in the buffer.
    /// Terminal delivery is NOT idempotent at the engine layer: an engine may
    /// emit `.ended`, and `teardown()` separately finishes the continuation, so
    /// the consumer must de-duplicate terminal reporting (e.g. a natural
    /// `.ended` followed by a teardown on dismissal). A future engine is free to
    /// strengthen this to a single terminal event; until then the guard lives in
    /// the view model.
    nonisolated var state: AsyncStream<PlaybackBeat> { get }

    /// Load the asset. Seeks to `asset.startTime` when the item becomes ready.
    /// Throws `PlaybackError` if the item cannot be prepared.
    ///
    /// Opens a new SESSION and returns its id. An engine is reloadable in place (the transcode
    /// re-anchor / track switch reuses it so the video layer survives the swap), so this is the
    /// boundary between the media being replaced and its replacement: every beat published from
    /// here on carries the returned id, and every beat the outgoing media still had in flight —
    /// buffered in the stream, or queued on a run loop against a callback installed for it —
    /// carries the previous one and is dropped by the engine's own yield funnel.
    @discardableResult
    func load(_ asset: PlayableAsset) async throws -> PlaybackSessionID

    /// Begin or resume playback.
    func play() async

    /// Pause playback.
    func pause() async

    /// Silence audio output for a session that will come BACK: the transcode reload
    /// freezes the frame, silences, swaps the stream and plays again, and the `play()`
    /// on the other side must restore audio. RESUMABLE, and therefore best-effort about
    /// how deep it reaches: VLC's implementation is a decode-side gain that cannot
    /// touch samples already handed to the audio output.
    func silence() async

    /// Silence audio output NOW and for good, ahead of a deferred teardown. Dismissal
    /// keeps the engine alive for the whole close animation (the last frame rides the
    /// card out), so audio needs a kill switch that does not wait for `teardown()`,
    /// and one that a late `play()` (a scrub commit coalesced just before the exit)
    /// cannot undo. TERMINAL for this session: only `load()` reopens it.
    func endAudio() async

    /// Seek to an arbitrary position. No-op if no item is loaded.
    ///
    /// **The seek-settle contract.** From the moment this is called until the engine resolves
    /// the seek, no position-carrying beat it publishes is `.observed` (see
    /// `PositionProvenance`): each one is labelled either `.projected` — the engine's own
    /// forward estimate off this target, safe to draw — or `.stale` — the engine's clock,
    /// still describing where the media was before the seek, safe to draw nowhere. The first
    /// `.observed` beat after this call carries a clock at or after the LATEST target:
    /// overlapping seeks yield nothing observed until the newest resolves, and a superseded
    /// one never yields any. An engine that gives up on a seek publishes the honest raw clock
    /// as `.observed` — it never republishes the pre-seek clock as if the seek had landed.
    /// See `PlaybackState`.
    ///
    /// What "resolved" means is per-engine and documented on each `seek(to:)` override:
    /// `VLCKitEngine` tests the clock's convergence on the target, `AVKitEngine` only knows
    /// that `AVPlayer` returned `finished == true` (weaker). An engine that can tell neither
    /// must report `.stale`.
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

    /// Default: `silence()`. An engine whose silence already stops the render pipeline on
    /// the spot (AVKit's pause does) needs nothing stronger on exit. Only VLC overrides,
    /// where mute is a per-block decode-side gain that leaves the ~1-2s already queued in
    /// the audio output playing, so the terminal cut there has to stop the player.
    func endAudio() async { await silence() }

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
