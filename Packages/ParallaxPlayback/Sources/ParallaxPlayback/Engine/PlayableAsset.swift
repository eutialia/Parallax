import Foundation
import CoreMedia
import ParallaxCore

public struct PlayableAsset: Sendable {
    public let url: URL
    public let headers: [String: String]?         // nil for AVKit (auth via api_key query param)
    public let hints: PlaybackHints
    public let startTime: CMTime?
    public let externalSubtitles: [ExternalSubtitle]   // empty in Phase 4
    /// Authoritative server-side track metadata used to label the engine's
    /// tracks (a transcode manifest often omits names/languages).
    public let mediaStreams: [MediaStreamInfo]
    /// Source stream index of the single transcoded audio/subtitle rendition,
    /// so the engine can name the one track the manifest carries.
    public let defaultAudioStreamIndex: Int?
    public let defaultSubtitleStreamIndex: Int?

    public init(
        url: URL,
        headers: [String: String]?,
        hints: PlaybackHints,
        startTime: CMTime?,
        externalSubtitles: [ExternalSubtitle],
        mediaStreams: [MediaStreamInfo] = [],
        defaultAudioStreamIndex: Int? = nil,
        defaultSubtitleStreamIndex: Int? = nil
    ) {
        self.url = url
        self.headers = headers
        self.hints = hints
        self.startTime = startTime
        self.externalSubtitles = externalSubtitles
        self.mediaStreams = mediaStreams
        self.defaultAudioStreamIndex = defaultAudioStreamIndex
        self.defaultSubtitleStreamIndex = defaultSubtitleStreamIndex
    }
}
