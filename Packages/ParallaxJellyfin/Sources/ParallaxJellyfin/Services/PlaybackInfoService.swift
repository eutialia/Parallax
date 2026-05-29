import Foundation
import CoreMedia
import JellyfinAPI
import ParallaxCore

/// Resolves a playable stream from Jellyfin and owns the progress-report
/// cadence. One per server (see PlaybackInfoServiceStore). Branches direct-play
/// vs transcode on `mediaSource.transcodingURL` — the server has final say.
public actor PlaybackInfoService {
    public static let ticksPerSecond: Int = 10_000_000

    private let client: JellyfinPlaybackClient

    /// Minimum seconds between throttled progress beats. A pause-flip or seek
    /// bypasses this and reports immediately.
    static let progressThrottleSeconds: Double = 10

    // Cadence state. `lastReportedAt` is the clock value of the last sent
    // progress/start beat; `lastPaused` detects pause flips.
    private var lastReportedAt: Double = 0
    private var lastPaused: Bool = false

    public init(client: JellyfinPlaybackClient) {
        self.client = client
    }

    // MARK: - Resolve

    public func resolve(
        item: ItemID,
        capabilities: DeviceCapabilities,
        startTime: CMTime?
    ) async throws -> ResolvedPlayback {
        let startTimeTicks = startTime.map(Self.ticks(from:))
        let profile = DeviceProfileTranslator.deviceProfile(from: capabilities)

        let response: PlaybackInfoResponse
        do {
            response = try await client.playbackInfo(
                itemID: item.rawValue,
                profile: profile,
                startTimeTicks: startTimeTicks
            )
        } catch {
            throw ErrorMapping.appError(from: error)
        }

        guard let source = response.mediaSources?.first else {
            throw AppError.unexpected(
                "PlaybackInfo returned no media sources for item \(item.rawValue)",
                underlying: nil
            )
        }

        let mediaSourceID = source.id ?? item.rawValue
        let playSessionID = response.playSessionID ?? ""
        let container = source.container.flatMap(Container.init(rawValue:))
        let videoCodec = Self.firstCodec(in: source, type: .video).flatMap(VideoCodec.init(identifier:))
        let audioCodec = Self.firstCodec(in: source, type: .audio).flatMap(AudioCodec.init(identifier:))
        let runtime = source.runTimeTicks.map { Self.cmTime(fromTicks: $0) }

        let method: PlaybackMethod
        let url: URL?
        if let transcodingURL = source.transcodingURL {
            // Server decided to transcode. Its URL already carries api_key.
            method = .transcode
            url = client.transcodeURL(relativePath: transcodingURL)
        } else {
            let isStatic = !(source.isSupportsDirectStream ?? false)
            method = isStatic ? .directPlay : .directStream
            url = client.streamURL(
                StreamRequest(
                    itemID: item.rawValue,
                    container: source.container ?? "mp4",
                    mediaSourceID: mediaSourceID,
                    playSessionID: playSessionID,
                    startTimeTicks: startTimeTicks ?? 0,
                    isStatic: isStatic
                )
            )
        }

        guard let url else {
            throw AppError.unexpected(
                "PlaybackInfo could not build a stream URL for item \(item.rawValue)",
                underlying: nil
            )
        }

        return ResolvedPlayback(
            itemID: item.rawValue,
            url: url,
            method: method,
            container: container,
            videoCodec: videoCodec,
            audioCodec: audioCodec,
            mediaSourceID: mediaSourceID,
            playSessionID: playSessionID,
            runtime: runtime,
            startTime: startTime
        )
    }

    // MARK: - Tick helpers

    /// Converts a `CMTime` position to Jellyfin's 100-nanosecond ticks. Public
    /// so the app's view model reports progress through the one canonical
    /// conversion instead of re-deriving `seconds * ticksPerSecond` inline.
    public static func ticks(from time: CMTime) -> Int {
        let seconds = CMTimeGetSeconds(time)
        guard seconds.isFinite, seconds > 0 else { return 0 }
        return Int((seconds * Double(ticksPerSecond)).rounded())
    }

    static func cmTime(fromTicks ticks: Int) -> CMTime {
        CMTime(value: CMTimeValue(ticks), timescale: CMTimeScale(ticksPerSecond))
    }

    private static func firstCodec(in source: MediaSourceInfo, type: MediaStreamType) -> String? {
        source.mediaStreams?.first(where: { $0.type == type })?.codec
    }

    // MARK: - Progress reporting

    public func reportStart(_ beat: ProgressBeat) async {
        lastReportedAt = 0
        lastPaused = beat.isPaused
        let info = stateInfo(from: beat)
        await send("reportStart") { try await self.client.reportStart(info) }
    }

    /// Throttled to ~10s; a pause flip or seek reports immediately. `now` is
    /// an injected clock (seconds) so cadence is deterministic in tests.
    public func reportProgress(_ beat: ProgressBeat, now: Double) async {
        let pauseFlipped = beat.isPaused != lastPaused
        let elapsed = now - lastReportedAt
        let throttled = elapsed >= Self.progressThrottleSeconds
        guard pauseFlipped || throttled else {
            lastPaused = beat.isPaused
            return
        }
        lastReportedAt = now
        lastPaused = beat.isPaused
        let info = stateInfo(from: beat)
        await send("reportProgress") { try await self.client.reportProgress(info) }
    }

    public func reportStopped(_ beat: ProgressBeat) async {
        let info = PlaybackStopInfo(
            itemID: beat.itemID,
            mediaSourceID: beat.mediaSourceID,
            playSessionID: beat.playSessionID,
            positionTicks: beat.positionTicks
        )
        await send("reportStopped") { try await self.client.reportStopped(info) }
    }

    // MARK: - Body translation + named non-fatal send

    private func stateInfo(from beat: ProgressBeat) -> PlaybackStateInfo {
        PlaybackStateInfo(
            isPaused: beat.isPaused,
            itemID: beat.itemID,
            mediaSourceID: beat.mediaSourceID,
            playMethod: Self.playMethod(from: beat.method),
            playSessionID: beat.playSessionID,
            positionTicks: beat.positionTicks
        )
    }

    private static func playMethod(from method: PlaybackMethod) -> PlayMethod {
        switch method {
        case .directPlay: return .directPlay
        case .directStream: return .directStream
        case .transcode: return .transcode
        }
    }

    // Named non-fatal policy: a thrown SDK request error is logged and
    // swallowed so a flaky report never tears down playback. The label names
    // the report so the swallowed failure is still traceable in the log.
    private func send(_ label: String, _ work: () async throws -> Void) async {
        do {
            try await work()
        } catch {
            Log.playback.error("\(label) failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
