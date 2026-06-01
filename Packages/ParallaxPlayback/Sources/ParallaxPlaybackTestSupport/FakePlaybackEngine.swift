import Foundation
import CoreMedia
import ParallaxPlayback

// MARK: — PlaybackEngineCapabilities convenience stubs

extension PlaybackEngineCapabilities {
    /// AVKit preset: all capabilities enabled.
    public static let avKit = PlaybackEngineCapabilities(
        supportsPiP: true,
        supportsVideoAirPlay: true,
        supportsAudioAirPlay: true,
        supportsNowPlayingIntegration: true
    )

    /// VLC preset: PiP + audio AirPlay + Now Playing; no video AirPlay.
    public static let vlcKit = PlaybackEngineCapabilities(
        supportsPiP: true,
        supportsVideoAirPlay: false,
        supportsAudioAirPlay: true,
        supportsNowPlayingIntegration: true
    )
}

// MARK: — FakePlaybackEngine

/// Deterministic `PlaybackEngine` test double.
///
/// - Push states via `push(_:)` — emitted to the `state` stream in order.
/// - Inspect recorded calls via `calls`, `loadedAssets`, `selectedAudioTrackID`, etc.
/// - `teardown()` finishes the stream so async `for await` loops terminate.
/// - Call `finish()` to close the stream without recording "teardown".
///
/// Thread-safety: this is a test double. Its recording fields are
/// `nonisolated(unsafe)` so the class can satisfy `PlaybackEngine`'s `Sendable`
/// requirement without actor isolation. The safety invariant is that all writes
/// happen inside the `async` protocol methods, and every consuming test suite
/// drives a given instance from a single actor context (the suites are
/// `@MainActor`). Do NOT call this engine's protocol methods from two concurrent
/// Tasks on the same instance — that would race the recording fields. Use one
/// instance per test.
public final class FakePlaybackEngine: PlaybackEngine {

    public nonisolated let id: PlaybackEngineID
    public nonisolated let capabilities: PlaybackEngineCapabilities
    public nonisolated let state: AsyncStream<PlaybackState>

    public nonisolated(unsafe) private(set) var loadedAssets: [PlayableAsset] = []
    public nonisolated(unsafe) private(set) var calls: [String] = []
    public nonisolated(unsafe) private(set) var selectedAudioTrackID: TrackID? = nil
    public nonisolated(unsafe) private(set) var selectedSubtitleTrackID: TrackID? = nil

    private let continuation: AsyncStream<PlaybackState>.Continuation

    public init(id: PlaybackEngineID, capabilities: PlaybackEngineCapabilities) {
        self.id = id
        self.capabilities = capabilities
        let (stream, cont) = AsyncStream<PlaybackState>.makeStream()
        self.state = stream
        self.continuation = cont
    }

    /// Push a state into the stream immediately.
    public func push(_ state: PlaybackState) {
        continuation.yield(state)
    }

    /// Finish the stream without recording a "teardown" call.
    public func finish() {
        continuation.finish()
    }

    public func load(_ asset: PlayableAsset) async throws {
        loadedAssets.append(asset)
        calls.append("load")
    }

    public func play() async { calls.append("play") }

    public func pause() async { calls.append("pause") }

    public func seek(to time: CMTime) async {
        let seconds = CMTimeGetSeconds(time)
        let formatted = String(format: "%.1f", seconds)
        calls.append("seek(\(formatted))")
    }

    public func setAudioTrack(_ track: AudioTrack) async {
        selectedAudioTrackID = track.id
        calls.append("setAudioTrack(\(track.id))")
    }

    public func setSubtitleTrack(_ track: SubtitleTrack?) async {
        selectedSubtitleTrackID = track?.id
        calls.append(track.map { "setSubtitleTrack(\($0.id))" } ?? "setSubtitleTrack(nil)")
    }

    public func teardown() async {
        calls.append("teardown")
        continuation.finish()
    }
}
