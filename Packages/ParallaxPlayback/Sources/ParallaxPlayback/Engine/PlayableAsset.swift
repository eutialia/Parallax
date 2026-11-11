import Foundation
import CoreMedia
import ParallaxCore

public struct PlayableAsset: Sendable {
    public let url: URL
    public let startTime: CMTime?
    /// Authoritative server-side track metadata used to label the engine's
    /// tracks (a transcode manifest often omits names/languages).
    public let mediaStreams: [MediaStreamInfo]
    /// Source stream index of the single transcoded audio/subtitle rendition,
    /// so the engine can name the one track the manifest carries.
    public let defaultAudioStreamIndex: Int?
    public let defaultSubtitleStreamIndex: Int?
    /// The app draws every text subtitle itself, so the engine must never draw one. Left alone,
    /// AVFoundation selects a default or forced legible option and renders it under the overlay.
    public let engineSubtitlesDisabled: Bool

    public init(
        url: URL,
        startTime: CMTime?,
        mediaStreams: [MediaStreamInfo] = [],
        defaultAudioStreamIndex: Int? = nil,
        defaultSubtitleStreamIndex: Int? = nil,
        engineSubtitlesDisabled: Bool = false
    ) {
        self.url = url
        self.startTime = startTime
        self.mediaStreams = mediaStreams
        self.defaultAudioStreamIndex = defaultAudioStreamIndex
        self.defaultSubtitleStreamIndex = defaultSubtitleStreamIndex
        self.engineSubtitlesDisabled = engineSubtitlesDisabled
    }
}
