import Foundation
import CoreMedia
@testable import ParallaxPlayback

// MARK: — PlaybackEngineCapabilities convenience

extension PlaybackEngineCapabilities {
    /// AVKit preset: all capabilities enabled.
    static let avKit = PlaybackEngineCapabilities(
        supportsPiP: true,
        supportsVideoAirPlay: true,
        supportsAudioAirPlay: true,
        supportsNowPlayingIntegration: true
    )
}

// MARK: — FakePlaybackEngine

/// Deterministic `PlaybackEngine` test double.
///
/// - Push states via `push(_:)` — they are emitted to the `state` stream in order.
/// - Inspect recorded calls via `calls`, `loadedAssets`, `selectedAudioTrackID`, etc.
/// - `teardown()` finishes the stream so async `for await` loops terminate.
///
/// Thread-safety: designed for test use (single test task); internal state is
/// protected by `nonisolated(unsafe)` because Swift Testing runs tests concurrently.
/// Each test should use its own `FakePlaybackEngine` instance.
final class FakePlaybackEngine: PlaybackEngine {

    // MARK: — Protocol requirements

    nonisolated let id: PlaybackEngineID
    nonisolated let capabilities: PlaybackEngineCapabilities
    nonisolated let state: AsyncStream<PlaybackState>

    // MARK: — Recording
    // nonisolated(unsafe): tests are single-threaded per instance; Swift's
    // Sendable checker cannot verify that, so we suppress the diagnostic.

    nonisolated(unsafe) private(set) var loadedAssets: [PlayableAsset] = []
    nonisolated(unsafe) private(set) var calls: [String] = []
    nonisolated(unsafe) private(set) var selectedAudioTrackID: String? = nil
    nonisolated(unsafe) private(set) var selectedSubtitleTrackID: String? = nil

    // MARK: — Private stream plumbing

    private let continuation: AsyncStream<PlaybackState>.Continuation

    // MARK: — Init

    init(id: PlaybackEngineID, capabilities: PlaybackEngineCapabilities) {
        self.id = id
        self.capabilities = capabilities
        let (stream, cont) = AsyncStream<PlaybackState>.makeStream()
        self.state = stream
        self.continuation = cont
    }

    // MARK: — Control API (test-only)

    /// Push a state into the stream immediately.
    func push(_ state: PlaybackState) {
        continuation.yield(state)
    }

    // MARK: — PlaybackEngine

    func load(_ asset: PlayableAsset) async throws {
        loadedAssets.append(asset)
        calls.append("load")
    }

    func play() async {
        calls.append("play")
    }

    func pause() async {
        calls.append("pause")
    }

    func seek(to time: CMTime) async {
        let seconds = CMTimeGetSeconds(time)
        // Round to one decimal place for stable string comparison in tests.
        let formatted = String(format: "%.1f", seconds)
        calls.append("seek(\(formatted))")
    }

    func setAudioTrack(_ track: AudioTrack) async {
        selectedAudioTrackID = track.id
        calls.append("setAudioTrack(\(track.id))")
    }

    func setSubtitleTrack(_ track: SubtitleTrack?) async {
        selectedSubtitleTrackID = track?.id
        calls.append(track.map { "setSubtitleTrack(\($0.id))" } ?? "setSubtitleTrack(nil)")
    }

    func teardown() async {
        calls.append("teardown")
        continuation.finish()
    }
}
