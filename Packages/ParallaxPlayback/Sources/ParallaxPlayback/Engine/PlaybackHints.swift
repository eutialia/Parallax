import Foundation
import ParallaxCore

public struct PlaybackHints: Sendable, Hashable {
    public let scheme: String?              // url.scheme; "smb" routes to VLC in Phase 5
    public let container: Container?
    public let videoCodec: VideoCodec?
    public let audioCodec: AudioCodec?
    public let subtitleFormats: [SubtitleFormat]

    public init(
        scheme: String?,
        container: Container?,
        videoCodec: VideoCodec?,
        audioCodec: AudioCodec?,
        subtitleFormats: [SubtitleFormat]
    ) {
        self.scheme = scheme
        self.container = container
        self.videoCodec = videoCodec
        self.audioCodec = audioCodec
        self.subtitleFormats = subtitleFormats
    }
}
