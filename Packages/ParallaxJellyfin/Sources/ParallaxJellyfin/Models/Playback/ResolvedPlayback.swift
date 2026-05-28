import Foundation
import CoreMedia
import ParallaxCore

/// A self-contained, playable stream resolved from Jellyfin. The `url`
/// already embeds `api_key` as a query parameter — AVPlayer does not send
/// the X-Emby-Authorization header on HLS segment fetches, so a header-only
/// URL would 401 silently mid-stream. Carries only Core enums + Jellyfin ids
/// so the app (not this package) can map it to a ParallaxPlayback.PlayableAsset.
public struct ResolvedPlayback: Sendable {
    public let url: URL
    public let method: PlaybackMethod
    public let container: Container?
    public let videoCodec: VideoCodec?
    public let audioCodec: AudioCodec?
    public let mediaSourceID: String
    public let playSessionID: String
    public let runtime: CMTime?
    public let startTime: CMTime?

    public init(
        url: URL,
        method: PlaybackMethod,
        container: Container?,
        videoCodec: VideoCodec?,
        audioCodec: AudioCodec?,
        mediaSourceID: String,
        playSessionID: String,
        runtime: CMTime?,
        startTime: CMTime?
    ) {
        self.url = url
        self.method = method
        self.container = container
        self.videoCodec = videoCodec
        self.audioCodec = audioCodec
        self.mediaSourceID = mediaSourceID
        self.playSessionID = playSessionID
        self.runtime = runtime
        self.startTime = startTime
    }
}
