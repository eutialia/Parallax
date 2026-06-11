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
        startTimeTicks: Int?,
        audioStreamIndex: Int?,
        subtitleStreamIndex: Int?
    ) async throws -> PlaybackInfoResponse

    func streamURL(_ request: StreamRequest) -> URL?
    func transcodeURL(relativePath: String) -> URL?

    /// A self-contained, authed URL for a single subtitle stream in `format`
    /// (e.g. "vtt"). Built with `copyTimestamps` so the sidecar carries ABSOLUTE
    /// cue times — the client fetches and renders this itself instead of the
    /// in-manifest HLS WebVTT, whose `X-TIMESTAMP-MAP` drifts on fMP4 segments
    /// (jellyfin/jellyfin#16647). `nil` if the URL can't be built.
    func subtitleStreamURL(itemID: String, mediaSourceID: String, streamIndex: Int, format: String) -> URL?

    func reportStart(_ info: PlaybackStateInfo) async throws
    func reportProgress(_ info: PlaybackStateInfo) async throws
    func reportStopped(_ info: PlaybackStopInfo) async throws

    /// Kills the server's active transcode job for a play session
    /// (`DELETE /Videos/ActiveEncodings`). MUST be called before resolving a
    /// replacement stream for the same item (track switch): with server-side
    /// throttling off, an abandoned 4K job keeps transcoding flat-out and
    /// starves the new job's segment production past AVPlayer's 3s timeout
    /// (-12889 livelock, device-diagnosed 2026-06-11). jellyfin-web fires this
    /// before every in-place stream change. No-op server-side if the job
    /// already ended.
    func stopEncoding(playSessionID: String) async throws

    /// Resets the server's 60s idle kill timer for a play session's transcode
    /// job (`POST /Sessions/Playing/Ping`). The server kills an idle job AND
    /// deletes its segments after 60s without a segment request or ping — and
    /// a paused AVPlayer stops requesting segments once its buffer fills (the
    /// periodic observer also goes quiet, so progress beats stop). Without
    /// pings, any pause >60s silently destroys the job and resume pays a cold
    /// ffmpeg respawn that presents as the endless-buffering wedge.
    func pingSession(playSessionID: String) async throws
}
