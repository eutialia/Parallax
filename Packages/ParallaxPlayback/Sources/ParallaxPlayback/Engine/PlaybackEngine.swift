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

    /// Seek to an arbitrary position. No-op if no item is loaded.
    func seek(to time: CMTime) async

    /// Select an audio track by id. No-op if the id is not in the current inventory.
    func setAudioTrack(_ track: AudioTrack) async

    /// Select a subtitle track by id, or pass nil to disable subtitles.
    func setSubtitleTrack(_ track: SubtitleTrack?) async

    /// Stop playback, remove observers, finish the state stream continuation.
    /// Must be called before releasing the engine.
    func teardown() async
}
