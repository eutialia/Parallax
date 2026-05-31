import Foundation
import JellyfinAPI

/// SDK-backed playback client. Builds a fresh JellyfinClient per call exactly
/// like DefaultJellyfinLibraryClient — cheap value-type config, no shared
/// mutable state. URL helpers use the public client.url(with:queryAPIKey:) /
/// client.url(path:) so api_key lands in the query.
public final class DefaultJellyfinPlaybackClient: JellyfinPlaybackClient, @unchecked Sendable {
    private let session: Session
    private let identity: DeviceIdentity

    public init(session: Session, identity: DeviceIdentity) {
        self.session = session
        self.identity = identity
    }

    private func client() -> JellyfinClient {
        let config = JellyfinClient.Configuration(
            url: session.serverURL,
            accessToken: session.accessToken,
            client: identity.client,
            deviceName: identity.deviceName,
            deviceID: identity.deviceID,
            version: identity.version
        )
        return JellyfinClient(configuration: config)
    }

    private var userID: String { session.user.id }

    // MARK: - Resolve

    public func playbackInfo(
        itemID: String,
        profile: DeviceProfile,
        startTimeTicks: Int?,
        audioStreamIndex: Int?,
        subtitleStreamIndex: Int?
    ) async throws -> PlaybackInfoResponse {
        var params = Paths.GetPostedPlaybackInfoParameters()
        params.userID = userID
        params.startTimeTicks = startTimeTicks
        // Force the server to build the transcode around a specific source
        // track (track switching on the transcode path). nil → server default.
        params.audioStreamIndex = audioStreamIndex
        params.subtitleStreamIndex = subtitleStreamIndex
        params.enableDirectPlay = true
        params.enableDirectStream = true
        params.enableTranscoding = true
        params.allowVideoStreamCopy = true
        params.allowAudioStreamCopy = true

        var body = PlaybackInfoDto(
            deviceProfile: profile,
            enableDirectPlay: true,
            enableDirectStream: true,
            enableTranscoding: true,
            startTimeTicks: startTimeTicks,
            userID: userID
        )
        body.audioStreamIndex = audioStreamIndex
        body.subtitleStreamIndex = subtitleStreamIndex

        let request = Paths.getPostedPlaybackInfo(itemID: itemID, parameters: params, body)
        return try await client().send(request).value
    }

    // MARK: - Stream URLs

    public func streamURL(_ request: StreamRequest) -> URL? {
        var params = Paths.GetVideoStreamByContainerParameters()
        params.isStatic = request.isStatic
        params.mediaSourceID = request.mediaSourceID
        params.playSessionID = request.playSessionID
        params.deviceID = identity.deviceID
        if request.startTimeTicks > 0 {
            params.startTimeTicks = request.startTimeTicks
        }
        let videoRequest = Paths.getVideoStreamByContainer(
            itemID: request.itemID,
            container: request.container,
            parameters: params
        )
        // queryAPIKey: true appends api_key to the query — AVPlayer won't
        // send the X-Emby-Authorization header on segment fetches.
        return client().url(with: videoRequest, queryAPIKey: true)
    }

    public func transcodeURL(relativePath: String) -> URL? {
        // The server's transcodingURL already contains every query param,
        // including api_key. We only resolve it against the server base URL.
        client().url(path: relativePath)
    }

    // MARK: - Progress reporting (non-deprecated /Sessions/Playing paths)

    public func reportStart(_ info: PlaybackStateInfo) async throws {
        try await client().send(Paths.reportPlaybackStart(info))
    }

    public func reportProgress(_ info: PlaybackStateInfo) async throws {
        try await client().send(Paths.reportPlaybackProgress(info))
    }

    public func reportStopped(_ info: PlaybackStopInfo) async throws {
        try await client().send(Paths.reportPlaybackStopped(info))
    }
}
