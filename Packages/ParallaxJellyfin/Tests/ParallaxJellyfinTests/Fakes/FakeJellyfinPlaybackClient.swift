import Foundation
import JellyfinAPI
@testable import ParallaxJellyfin

/// Programmable stand-in for the SDK-backed playback client.
///
/// The canned URLs are deliberately OPAQUE SENTINELS, not imitations of the real ones: a fake that
/// fabricated `api_key=…&master.m3u8` would let a resolve test "prove" URL construction that the
/// fake itself wrote. URL shape belongs to `DefaultJellyfinPlaybackClientTests`, where the real
/// builder runs; here the only URL fact worth asserting is that `resolve` returned the sentinel
/// the corresponding builder was asked for — i.e. the wiring.
///
/// Every method body runs under `lock`: the service is an actor but the fake is shared state, and
/// its library counterpart already needed the same guard after a lost-append flake.
final class FakeJellyfinPlaybackClient: JellyfinPlaybackClient, @unchecked Sendable {
    private let lock = NSLock()

    // Programmable responses.
    var playbackInfoResult: Result<PlaybackInfoResponse, Error> = .success(PlaybackInfoResponse())
    var streamURLValue = URL(string: "https://fake.invalid/direct-play-sentinel")
    var transcodeURLValue = URL(string: "https://fake.invalid/transcode-sentinel")
    /// Returns a per-index sentinel so a test can tell one subtitle stream's URL from another's
    /// without the fake pretending to know the real endpoint's shape.
    var subtitleURLForIndex: @Sendable (Int) -> URL? = { URL(string: "https://fake.invalid/subtitle-sentinel/\($0)") }
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
        try lock.withLock {
            playbackInfoCalls.append((itemID, profile, startTimeTicks, audioStreamIndex, subtitleStreamIndex))
            return try playbackInfoResult.get()
        }
    }

    func streamURL(_ request: StreamRequest) -> URL? {
        lock.withLock {
            streamURLRequests.append(request)
            return streamURLValue
        }
    }

    func transcodeURL(relativePath: String) -> URL? {
        lock.withLock {
            transcodePaths.append(relativePath)
            return transcodeURLValue
        }
    }

    func subtitleStreamURL(itemID: String, mediaSourceID: String, streamIndex: Int, format: String) -> URL? {
        lock.withLock {
            subtitleStreamURLRequests.append((itemID, mediaSourceID, streamIndex, format))
            return subtitleURLForIndex(streamIndex)
        }
    }

    func reportStart(_ info: PlaybackStateInfo) async throws {
        try lock.withLock {
            startInfos.append(info)
            if let startError { throw startError }
        }
    }

    func reportProgress(_ info: PlaybackStateInfo) async throws {
        try lock.withLock {
            progressInfos.append(info)
            if let progressError { throw progressError }
        }
    }

    func reportStopped(_ info: PlaybackStopInfo) async throws {
        try lock.withLock {
            stoppedInfos.append(info)
            if let stoppedError { throw stoppedError }
        }
    }

    func stopEncoding(playSessionID: String) async throws {
        try lock.withLock {
            stopEncodingSessionIDs.append(playSessionID)
            if let stopEncodingError { throw stopEncodingError }
        }
    }

    func pingSession(playSessionID: String) async throws {
        try lock.withLock {
            pingSessionIDs.append(playSessionID)
            if let pingError { throw pingError }
        }
    }

    // Delivery probe.
    var transcodingDeliveryResult: Result<TranscodeDelivery?, Error> = .success(nil)
    private(set) var transcodingDeliveryCalls: [String] = []

    func transcodingDelivery(playSessionID: String) async throws -> TranscodeDelivery? {
        try lock.withLock {
            transcodingDeliveryCalls.append(playSessionID)
            return try transcodingDeliveryResult.get()
        }
    }

    // User configuration round-trip.
    var userConfigurationResult: Result<UserConfiguration, Error> = .success(UserConfiguration())
    var updateUserConfigurationError: Error?
    private(set) var userConfigurationFetchCount = 0
    private(set) var updatedUserConfigurations: [UserConfiguration] = []

    func currentUserConfiguration() async throws -> UserConfiguration {
        try lock.withLock {
            userConfigurationFetchCount += 1
            return try userConfigurationResult.get()
        }
    }

    func updateUserConfiguration(_ configuration: UserConfiguration) async throws {
        try lock.withLock {
            updatedUserConfigurations.append(configuration)
            if let updateUserConfigurationError { throw updateUserConfigurationError }
        }
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
