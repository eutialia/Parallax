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

    static func ticks(from time: CMTime) -> Int {
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
}
