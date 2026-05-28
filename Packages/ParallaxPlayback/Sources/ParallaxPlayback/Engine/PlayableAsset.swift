import Foundation
import CoreMedia

public struct PlayableAsset: Sendable {
    public let url: URL
    public let headers: [String: String]?         // nil for AVKit (auth via api_key query param)
    public let hints: PlaybackHints
    public let startTime: CMTime?
    public let externalSubtitles: [ExternalSubtitle]   // empty in Phase 4

    public init(
        url: URL,
        headers: [String: String]?,
        hints: PlaybackHints,
        startTime: CMTime?,
        externalSubtitles: [ExternalSubtitle]
    ) {
        self.url = url
        self.headers = headers
        self.hints = hints
        self.startTime = startTime
        self.externalSubtitles = externalSubtitles
    }
}
