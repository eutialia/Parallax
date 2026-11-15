import Foundation
import CoreMedia

/// The engine abstraction. Single-consumer `state` stream — `PlayerViewModel`
/// is the sole reader. `AVKitEngine` conforms, and tests use a fake. All `async` methods are witnessed by `@MainActor` methods on concrete
/// engines; the `nonisolated` synchronous requirements use `nonisolated let` storage.
public protocol PlaybackEngine: AnyObject, Sendable {
    /// The live playback clock, smooth enough for sub-second cue timing (the `state`
    /// stream's ~0.5s beats are too coarse). Read directly by the client-side subtitle
    /// overlay so it can sync cues against any engine. An engine may report `.invalid`
    /// while it has no position worth drawing to, so readers must gate on `isValid` rather
    /// than treat it as 0:00.
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
    /// Throws `PlaybackError` if the item cannot be prepared, and `CancellationError` if a
    /// teardown or another load supersedes it before its item reaches the player.
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
    /// What "resolved" means is documented on each `seek(to:)` override: `AVKitEngine` knows
    /// only that `AVPlayer` returned `finished == true`. An engine that cannot tell must
    /// report `.stale`.
    func seek(to time: CMTime) async

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

    /// Set the playback rate (1.0 = normal). Persisted by the engine so a
    /// later `play()` resumes at the chosen speed.
    func setRate(_ rate: Float) async

    /// Best-effort single-frame capture near the current playback position, for SMB thumbnail
    /// backfill (see `PlayerViewModel` in the app target). Must never throw and must never stall
    /// or otherwise perturb playback — any failure (no active item, decode error, API unsupported
    /// on this engine) returns nil. The returned Data is an already-encoded still image (HEIC or
    /// JPEG — see below), not raw pixels.
    func captureFrame() async -> Data?
}

public extension PlaybackEngine {
    /// Default: zero. Real engines override with their live clock.
    nonisolated var currentTime: CMTime { .zero }

    /// Default: no debug info. Concrete engines override with real telemetry.
    func debugSnapshot() async -> PlaybackDebugInfo { .empty }

    /// Default: no-op. Engines that support variable-speed playback override.
    func setRate(_ rate: Float) async {}

    /// Default: nil. A fake engine never pays for a capture the backfill would discard.
    func captureFrame() async -> Data? { nil }
}
