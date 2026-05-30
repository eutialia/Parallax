import Foundation
import CoreMedia
@testable import Parallax
import ParallaxPlayback
import ParallaxPlaybackTestSupport
@testable import ParallaxJellyfin
@testable import ParallaxCore

// FakePlaybackEngine, PlaybackEngineCapabilities.avKit, and FakeCapabilityProbe
// are imported from ParallaxPlaybackTestSupport.

struct NoopAudioSession: AudioSessionControlling {
    let routeChanges: AsyncStream<Void> = AsyncStream { _ in }
    func activate() async throws {}
    func deactivate() async {}
}

struct ThrowingAudioSession: AudioSessionControlling {
    let routeChanges: AsyncStream<Void> = AsyncStream { _ in }
    func activate() async throws {
        throw NSError(domain: NSOSStatusErrorDomain, code: -50)
    }
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

    /// A server-transcoded MKV (bug #2): the *source* is MKV / AV1 / DTS — none
    /// of which AVKit can direct-play — but the server delivers an HLS transcode
    /// stream AVKit *can* play. The engine selector must gate on the delivered
    /// stream (HLS), not the source container.
    static func resolvedTranscodedMKV() -> ResolvedPlayback {
        ResolvedPlayback(
            itemID: "movie-1",
            url: URL(string: "https://jf.example.com/videos/movie-1/master.m3u8?api_key=abc")!,
            method: .transcode,
            container: .mkv,
            videoCodec: .av1,
            audioCodec: .dts,
            mediaSourceID: "ms-1",
            playSessionID: "ps-1",
            runtime: CMTime(seconds: 7200, preferredTimescale: 600),
            startTime: nil
        )
    }

    /// VC-1 MKV direct-play — routes to .vlcKit because .vc1 is not in
    /// EngineSelector's avKitVideoCodecs set.
    static func resolvedVC1MKV() -> ResolvedPlayback {
        ResolvedPlayback(
            itemID: "movie-2",
            url: URL(string: "https://jf.example.com/Videos/movie-2/stream.mkv?api_key=abc")!,
            method: .directPlay,
            container: .mkv,
            videoCodec: .vc1,
            audioCodec: .dts,
            mediaSourceID: "ms-2",
            playSessionID: "ps-2",
            runtime: CMTime(seconds: 5400, preferredTimescale: 600),
            startTime: nil
        )
    }

    /// A VP9/WebM/Opus direct-play item — container and codec both outside the AVKit
    /// whitelist, so EngineSelector routes it to .vlcKit.
    static func resolvedVP9WebM() -> ResolvedPlayback {
        ResolvedPlayback(
            itemID: "movie-2",
            url: URL(string: "https://jf.example.com/Videos/movie-2/stream.webm?api_key=abc")!,
            method: .directPlay,
            container: .webm,
            videoCodec: .vp9,
            audioCodec: .opus,
            mediaSourceID: "ms-2",
            playSessionID: "ps-2",
            runtime: CMTime(seconds: 3600, preferredTimescale: 600),
            startTime: nil
        )
    }
}
