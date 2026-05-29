import Foundation
import JellyfinAPI

/// Describes a direct-play / direct-stream video request. Kept SDK-free so
/// the protocol doesn't leak JellyfinAPI's `Request` type to callers.
public struct StreamRequest: Sendable, Hashable {
    public let itemID: String
    public let container: String
    public let mediaSourceID: String
    public let playSessionID: String
    public let startTimeTicks: Int
    public let isStatic: Bool

    public init(
        itemID: String,
        container: String,
        mediaSourceID: String,
        playSessionID: String,
        startTimeTicks: Int,
        isStatic: Bool
    ) {
        self.itemID = itemID
        self.container = container
        self.mediaSourceID = mediaSourceID
        self.playSessionID = playSessionID
        self.startTimeTicks = startTimeTicks
        self.isStatic = isStatic
    }
}

/// Narrow client the PlaybackInfoService calls. Exposes the SDK
/// PlaybackInfoResponse on purpose — DTO/codec translation happens in the
/// service, mirroring how JellyfinLibraryClient hands BaseItemDto upward.
/// `streamURL` / `transcodeURL` return self-contained URLs (api_key in the
/// query) so AVPlayer can fetch HLS segments without an auth header.
public protocol JellyfinPlaybackClient: Sendable {
    func playbackInfo(
        itemID: String,
        profile: DeviceProfile,
        startTimeTicks: Int?
    ) async throws -> PlaybackInfoResponse

    func streamURL(_ request: StreamRequest) -> URL?
    func transcodeURL(relativePath: String) -> URL?

    func reportStart(_ info: PlaybackStateInfo) async throws
    func reportProgress(_ info: PlaybackStateInfo) async throws
    func reportStopped(_ info: PlaybackStopInfo) async throws
}
