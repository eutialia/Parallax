import Foundation
import CoreMedia
@testable import Parallax
@testable import ParallaxPlayback
@testable import ParallaxJellyfin
@testable import ParallaxCore

/// Deterministic PlaybackEngine for the app integration test. Records calls and
/// lets the test script PlaybackStates into the single-consumer state stream.
@MainActor
final class FakePlaybackEngine: PlaybackEngine {
    nonisolated let id: PlaybackEngineID = .avKit
    nonisolated let capabilities = PlaybackEngineCapabilities(
        supportsPiP: true, supportsVideoAirPlay: true,
        supportsAudioAirPlay: true, supportsNowPlayingIntegration: true
    )

    nonisolated let state: AsyncStream<PlaybackState>
    private nonisolated let continuation: AsyncStream<PlaybackState>.Continuation

    private(set) var loadedAsset: PlayableAsset?
    private(set) var didPlay = false
    private(set) var didTeardown = false

    init() {
        let (stream, continuation) = AsyncStream<PlaybackState>.makeStream()
        self.state = stream
        self.continuation = continuation
    }

    func push(_ state: PlaybackState) { continuation.yield(state) }
    func finish() { continuation.finish() }

    func load(_ asset: PlayableAsset) async throws { loadedAsset = asset }
    func play() async { didPlay = true }
    func pause() async {}
    func seek(to time: CMTime) async {}
    func setAudioTrack(_ track: AudioTrack) async {}
    func setSubtitleTrack(_ track: SubtitleTrack?) async {}
    func teardown() async { didTeardown = true; continuation.finish() }
}

/// Local CapabilityProbe fake — the package test fake (FakeCapabilityProbe in
/// ParallaxPlaybackTests) isn't visible to the app test target.
struct StubCapabilityProbe: CapabilityProbe {
    let hdr: HDRSupport
    let audio: AudioOutputCapability
    @MainActor func hdrSupport() -> HDRSupport { hdr }
    func audioOutput() -> AudioOutputCapability { audio }
}

/// No-op AudioSessionControlling — activation/deactivation are real-device
/// concerns covered by the manual gate (Task 4d.8).
struct NoopAudioSession: AudioSessionControlling {
    let routeChanges: AsyncStream<Void> = AsyncStream { _ in }
    func activate() async throws {}
    func deactivate() async {}
}

enum PlayerFixtures {
    static func movieDetail(positionTicks: Int64 = 0) -> ItemDetail {
        let movie = Movie(
            id: ItemID(rawValue: "movie-1"),
            title: "Fixture Movie",
            overview: nil,
            year: 2024,
            runtime: .seconds(7200),
            communityRating: nil,
            officialRating: nil,
            genres: [],
            primaryTag: nil,
            backdropTags: [],
            logoTag: nil,
            thumbTag: nil,
            userData: UserItemData(
                played: false,
                playbackPositionTicks: positionTicks,
                playCount: 0,
                isFavorite: false
            )
        )
        return .movie(MovieDetail(movie: movie, tagline: nil, studios: [], people: []))
    }

    static func resolved() -> ResolvedPlayback {
        ResolvedPlayback(
            itemID: "movie-1",
            url: URL(string: "https://jf.example.com/Videos/movie-1/stream.m3u8?api_key=abc")!,
            method: .directPlay,
            container: .mp4,
            videoCodec: .h264,
            audioCodec: .aac,
            mediaSourceID: "ms-1",
            playSessionID: "ps-1",
            runtime: CMTime(seconds: 7200, preferredTimescale: 600),
            startTime: nil
        )
    }
}
