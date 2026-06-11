import Foundation
import JellyfinAPI
@testable import ParallaxJellyfin

final class FakeJellyfinPlaybackClient: JellyfinPlaybackClient, @unchecked Sendable {
    // Programmable responses.
    var playbackInfoResult: Result<PlaybackInfoResponse, Error> = .success(PlaybackInfoResponse())
    // Canned URLs — both carry api_key so resolve tests can assert auth.
    var streamURLValue = URL(string: "https://fake.example.com/Videos/x/stream.mp4?api_key=tok-1&mediaSourceId=ms-1")
    var transcodeURLValue = URL(string: "https://fake.example.com/videos/x/master.m3u8?api_key=tok-1&PlaySessionId=ps-1")
    // Per-call failures so the named non-fatal policy can be exercised.
    var startError: Error?
    var progressError: Error?
    var stoppedError: Error?
    var stopEncodingError: Error?

    // Call records.
    private(set) var playbackInfoCalls: [(itemID: String, profile: DeviceProfile, startTimeTicks: Int?, audioStreamIndex: Int?, subtitleStreamIndex: Int?)] = []
    private(set) var streamURLRequests: [StreamRequest] = []
    private(set) var transcodePaths: [String] = []
    private(set) var subtitleStreamURLRequests: [(itemID: String, mediaSourceID: String, streamIndex: Int, format: String)] = []
    private(set) var startInfos: [PlaybackStateInfo] = []
    private(set) var progressInfos: [PlaybackStateInfo] = []
    private(set) var stoppedInfos: [PlaybackStopInfo] = []
    private(set) var stopEncodingSessionIDs: [String] = []
    private(set) var pingSessionIDs: [String] = []
    var pingError: Error?

    enum FakeError: Error { case reportFailed }

    func playbackInfo(
        itemID: String,
        profile: DeviceProfile,
        startTimeTicks: Int?,
        audioStreamIndex: Int?,
        subtitleStreamIndex: Int?
    ) async throws -> PlaybackInfoResponse {
        playbackInfoCalls.append((itemID, profile, startTimeTicks, audioStreamIndex, subtitleStreamIndex))
        return try playbackInfoResult.get()
    }

    func streamURL(_ request: StreamRequest) -> URL? {
        streamURLRequests.append(request)
        return streamURLValue
    }

    func transcodeURL(relativePath: String) -> URL? {
        transcodePaths.append(relativePath)
        return transcodeURLValue
    }

    func subtitleStreamURL(itemID: String, mediaSourceID: String, streamIndex: Int, format: String) -> URL? {
        subtitleStreamURLRequests.append((itemID, mediaSourceID, streamIndex, format))
        return URL(string: "https://fake.example.com/Videos/\(itemID)/\(mediaSourceID)/Subtitles/\(streamIndex)/Stream.\(format)?api_key=tok-1&copyTimestamps=true")
    }

    func reportStart(_ info: PlaybackStateInfo) async throws {
        startInfos.append(info)
        if let startError { throw startError }
    }

    func reportProgress(_ info: PlaybackStateInfo) async throws {
        progressInfos.append(info)
        if let progressError { throw progressError }
    }

    func reportStopped(_ info: PlaybackStopInfo) async throws {
        stoppedInfos.append(info)
        if let stoppedError { throw stoppedError }
    }

    func stopEncoding(playSessionID: String) async throws {
        stopEncodingSessionIDs.append(playSessionID)
        if let stopEncodingError { throw stopEncodingError }
    }

    func pingSession(playSessionID: String) async throws {
        pingSessionIDs.append(playSessionID)
        if let pingError { throw pingError }
    }
}

final class FakeJellyfinPlaybackClientFactory: JellyfinPlaybackClientFactory, @unchecked Sendable {
    private var clientsBySession: [ServerID: FakeJellyfinPlaybackClient] = [:]
    private(set) var makeCalls: [ServerID] = []

    func client(for session: Session) -> FakeJellyfinPlaybackClient {
        if let existing = clientsBySession[session.id] { return existing }
        let new = FakeJellyfinPlaybackClient()
        clientsBySession[session.id] = new
        return new
    }

    func make(for session: Session) async -> JellyfinPlaybackClient {
        makeCalls.append(session.id)
        return client(for: session)
    }
}
