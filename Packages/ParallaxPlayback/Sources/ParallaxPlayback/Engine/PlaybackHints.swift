import Foundation
import ParallaxCore

/// Format metadata the caller already knows about a source, passed to `play(url:headers:hints:)`
/// so the engine selector can route without re-probing the URL. Everything is optional — the
/// engine falls back to its own inspection when a hint is absent.
public struct PlaybackHints: Sendable, Hashable {
    /// The URL scheme (e.g. `smb` routes to VLCKit; `http`/`https` default to AVKit).
    public let scheme: String?
    /// The media container, if known.
    public let container: Container?
    /// The video codec, if known.
    public let videoCodec: VideoCodec?
    /// The audio codec, if known.
    public let audioCodec: AudioCodec?
    /// The subtitle formats present, used to decide sidecar vs embedded rendering.
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
