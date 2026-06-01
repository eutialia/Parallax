import Foundation
import CoreMedia
import ParallaxCore

/// A self-contained, playable stream resolved from Jellyfin. The `url`
/// already embeds `api_key` as a query parameter — AVPlayer does not send
/// the X-Emby-Authorization header on HLS segment fetches, so a header-only
/// URL would 401 silently mid-stream. Carries only Core enums + Jellyfin ids
/// so the app (not this package) can map it to a ParallaxPlayback.PlayableAsset.
/// `itemID` makes the value self-describing: progress reporting needs the
/// source item id, so the consumer reads it from here rather than tracking it
/// in parallel.
public struct ResolvedPlayback: Sendable {
    public let itemID: String
    public let url: URL
    public let method: PlaybackMethod
    public let container: Container?
    public let videoCodec: VideoCodec?
    public let audioCodec: AudioCodec?
    public let mediaSourceID: String
    public let playSessionID: String
    public let runtime: CMTime?
    public let startTime: CMTime?
    /// Authoritative per-stream track metadata from the source. The player uses
    /// it to label tracks (a transcode manifest often omits names/languages).
    public let mediaStreams: [MediaStreamInfo]
    /// The source stream index the server chose for the (single) transcoded
    /// audio / subtitle, so the player can name the one rendition the manifest
    /// actually carries. `nil` when the server didn't specify one.
    public let defaultAudioStreamIndex: Int?
    public let defaultSubtitleStreamIndex: Int?
    /// Why the server is transcoding (e.g. "ContainerNotSupported",
    /// "AudioCodecNotSupported"), parsed from the transcoding URL. Empty for
    /// direct-play/-stream or when the server didn't say.
    public let transcodeReasons: [String]

    public init(
        itemID: String,
        url: URL,
        method: PlaybackMethod,
        container: Container?,
        videoCodec: VideoCodec?,
        audioCodec: AudioCodec?,
        mediaSourceID: String,
        playSessionID: String,
        runtime: CMTime?,
        startTime: CMTime?,
        mediaStreams: [MediaStreamInfo] = [],
        defaultAudioStreamIndex: Int? = nil,
        defaultSubtitleStreamIndex: Int? = nil,
        transcodeReasons: [String] = []
    ) {
        self.itemID = itemID
        self.url = url
        self.method = method
        self.container = container
        self.videoCodec = videoCodec
        self.audioCodec = audioCodec
        self.mediaSourceID = mediaSourceID
        self.playSessionID = playSessionID
        self.runtime = runtime
        self.startTime = startTime
        self.mediaStreams = mediaStreams
        self.defaultAudioStreamIndex = defaultAudioStreamIndex
        self.defaultSubtitleStreamIndex = defaultSubtitleStreamIndex
        self.transcodeReasons = transcodeReasons
    }
}
