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

    static func movieDetailNamed(_ title: String, positionTicks: Int64 = 0) -> ItemDetail {
        let movie = Movie(
            id: ItemID(rawValue: "movie-1"),
            title: title,
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

    /// A movie detail carrying chapter markers — for the `chapterFractions` memoization.
    /// `runtime` and the chapter starts are caller-chosen so the expected fractions are exact.
    static func movieDetailWithChapters(startsSeconds: [Double], runtime: Duration) -> ItemDetail {
        let movie = Movie(
            id: ItemID(rawValue: "movie-1"),
            title: "Chaptered Movie",
            overview: nil,
            year: 2024,
            runtime: runtime,
            communityRating: nil,
            officialRating: nil,
            genres: [],
            primaryTag: nil,
            backdropTags: [],
            logoTag: nil,
            thumbTag: nil,
            userData: UserItemData(
                played: false,
                playbackPositionTicks: 0,
                playCount: 0,
                isFavorite: false
            )
        )
        let chapters = startsSeconds.enumerated().map { index, seconds in
            Chapter(index: index, name: "Chapter \(index + 1)", start: .seconds(seconds))
        }
        return .movie(MovieDetail(movie: movie, tagline: nil, studios: [], people: [], chapters: chapters))
    }

    /// An episode `ItemDetail` (carries `seriesID`, so adjacency wiring applies).
    static func episodeDetail(
        id: String,
        seriesID: String = "series-1",
        name: String = "Episode",
        season: Int = 1,
        number: Int = 1,
        positionTicks: Int64 = 0,
        runtime: Duration = .seconds(1800)
    ) -> ItemDetail {
        let episode = Episode(
            id: ItemID(rawValue: id),
            seriesID: ItemID(rawValue: seriesID),
            seasonID: ItemID(rawValue: "season-\(season)"),
            name: name,
            indexNumber: number,
            parentIndexNumber: season,
            overview: nil,
            runtime: runtime,
            primaryTag: nil,
            userData: UserItemData(played: false, playbackPositionTicks: positionTicks, playCount: 0, isFavorite: false)
        )
        return .episode(EpisodeDetail(episode: episode, people: []))
    }

    /// A plain `Episode` — an adjacency neighbor (prev/next), not a full detail.
    static func episode(id: String, seriesID: String = "series-1", season: Int = 1, number: Int = 1) -> Episode {
        Episode(
            id: ItemID(rawValue: id),
            seriesID: ItemID(rawValue: seriesID),
            seasonID: ItemID(rawValue: "season-\(season)"),
            name: "S\(season)E\(number)",
            indexNumber: number,
            parentIndexNumber: season,
            overview: nil,
            runtime: .seconds(1800),
            primaryTag: nil,
            userData: UserItemData(played: false, playbackPositionTicks: 0, playCount: 0, isFavorite: false)
        )
    }

    /// A direct-play `ResolvedPlayback` for an arbitrary episode id — used by the
    /// succession tests whose resolve closure keys on the requested item.
    static func resolvedEpisode(id: String) -> ResolvedPlayback {
        ResolvedPlayback(
            itemID: id,
            url: URL(string: "https://jf.example.com/Videos/\(id)/stream.m3u8?api_key=abc")!,
            method: .directPlay,
            container: .mp4,
            videoCodec: .h264,
            audioCodec: .aac,
            mediaSourceID: "ms-\(id)",
            playSessionID: "ps-\(id)",
            runtime: CMTime(seconds: 1800, preferredTimescale: 600),
            startTime: nil
        )
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

    /// A transcoded MKV with a full multi-track source: 3 audio + 2 subtitle
    /// streams. The HLS transcode only carries the default rendition, so the
    /// menus must come from `mediaStreams` and switching re-resolves.
    static func resolvedMultiTrackTranscode(
        startTime: CMTime? = nil,
        defaultSubtitleStreamIndex: Int? = 1
    ) -> ResolvedPlayback {
        func audio(_ i: Int, _ title: String) -> MediaStreamInfo {
            MediaStreamInfo(index: i, kind: .audio, displayTitle: title, language: "jpn",
                            codec: "truehd", channels: 8, isExternal: false, isForced: false, isDefault: i == 3)
        }
        func sub(_ i: Int, _ title: String, _ lang: String, _ codec: String = "subrip") -> MediaStreamInfo {
            MediaStreamInfo(index: i, kind: .subtitle, displayTitle: title, language: lang,
                            codec: codec, channels: nil, isExternal: true, isForced: false, isDefault: i == 1)
        }
        return ResolvedPlayback(
            itemID: "movie-1",
            url: URL(string: "https://jf.example.com/videos/movie-1/master.m3u8?api_key=abc")!,
            method: .transcode,
            container: .mkv,
            videoCodec: .hevc,
            audioCodec: .trueHD,
            mediaSourceID: "ms-1",
            playSessionID: "ps-1",
            runtime: CMTime(seconds: 7200, preferredTimescale: 600),
            startTime: startTime,
            mediaStreams: [
                audio(3, "Surround 7.1 - Japanese - Default"),
                audio(4, "Surround 5.1 - Japanese"),
                audio(5, "Stereo - Japanese"),
                sub(1, "Chinese", "zho"),                       // text (SubRip)
                sub(7, "English - PGSSUB", "eng", "pgssub"),    // image — filtered out (burn-in only)
            ],
            defaultAudioStreamIndex: 3,
            defaultSubtitleStreamIndex: defaultSubtitleStreamIndex,
            subtitleStreamURLs: [
                1: URL(string: "https://jf.example.com/Videos/movie-1/ms-1/Subtitles/1/Stream.vtt?api_key=abc&copyTimestamps=true")!
            ]
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

    /// A VLC direct-play MKV with VC-1 video (routes to .vlcKit).
    static func resolvedVLCDirectPlayMKV() -> ResolvedPlayback {
        ResolvedPlayback(
            itemID: "movie-2",
            url: URL(string: "https://jf.example.com/Videos/movie-2/stream.mkv?api_key=abc")!,
            method: .directPlay, container: .mkv, videoCodec: .vc1, audioCodec: .aac,
            mediaSourceID: "ms-2", playSessionID: "ps-2",
            runtime: CMTime(seconds: 5400, preferredTimescale: 600), startTime: nil
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
