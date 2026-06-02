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
        startTime: CMTime?,
        audioStreamIndex: Int? = nil,
        subtitleStreamIndex: Int? = nil
    ) async throws -> ResolvedPlayback {
        let startTimeTicks = startTime.map(Self.ticks(from:))
        let profile = DeviceProfileTranslator.deviceProfile(from: capabilities)

        let response: PlaybackInfoResponse
        do {
            response = try await client.playbackInfo(
                itemID: item.rawValue,
                profile: profile,
                startTimeTicks: startTimeTicks,
                audioStreamIndex: audioStreamIndex,
                subtitleStreamIndex: subtitleStreamIndex
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
            // No server transcode: our device profile only advertises AVKit-native
            // containers + codecs for direct playback, so a non-transcode source is
            // directly playable. Serve it raw (static=true). AVPlayer requires HTTP
            // byte-range support for progressive playback, which the raw file
            // provides but Jellyfin's on-the-fly remux (static=false) does not — the
            // remux answers 200/chunked, which AVFoundation rejects
            // (NSOSStatusErrorDomain -12939 → AVFoundationErrorDomain -11850). True
            // remux/transcode is delivered as HLS via transcodingURL (handled above),
            // never the progressive static=false endpoint.
            method = .directPlay
            url = client.streamURL(
                StreamRequest(
                    itemID: item.rawValue,
                    container: source.container ?? "mp4",
                    mediaSourceID: mediaSourceID,
                    playSessionID: playSessionID,
                    startTimeTicks: startTimeTicks ?? 0,
                    isStatic: true
                )
            )
        }

        guard let url else {
            throw AppError.unexpected(
                "PlaybackInfo could not build a stream URL for item \(item.rawValue)",
                underlying: nil
            )
        }

        // Diagnostic: what are we actually handing the engine? video
        // profile + bit depth distinguish a decodable stream from one the
        // device/simulator can't handle (e.g. 10-bit H.264 that iOS won't
        // hardware-decode), and `method` shows direct-play vs HLS. URL is
        // hashed because it embeds api_key.
        let videoStream = source.mediaStreams?.first(where: { $0.type == .video })
        Log.playback.info(
            """
            resolve item=\(item.rawValue, privacy: .public) \
            method=\(String(describing: method), privacy: .public) \
            container=\(source.container ?? "nil", privacy: .public) \
            video=\(videoStream?.codec ?? "nil", privacy: .public)/\(videoStream?.profile ?? "nil", privacy: .public) \
            bitDepth=\(videoStream?.bitDepth.map(String.init) ?? "nil", privacy: .public) \
            res=\(videoStream?.width ?? 0, privacy: .public)x\(videoStream?.height ?? 0, privacy: .public) \
            audio=\(Self.firstCodec(in: source, type: .audio) ?? "nil", privacy: .public) \
            url=\(url.absoluteString, privacy: .private(mask: .hash))
            """
        )

        let streams = Self.mediaStreamInfos(from: source)
        let subtitleURLs = Self.subtitleStreamURLs(
            streams: streams,
            itemID: item.rawValue,
            mediaSourceID: mediaSourceID,
            client: client
        )

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
            startTime: startTime,
            mediaStreams: streams,
            defaultAudioStreamIndex: source.defaultAudioStreamIndex,
            defaultSubtitleStreamIndex: source.defaultSubtitleStreamIndex,
            subtitleStreamURLs: subtitleURLs,
            transcodeReasons: Self.transcodeReasons(from: source.transcodingURL)
        )
    }

    /// Builds an authed sidecar WebVTT URL per TEXT subtitle stream. Image subs
    /// (PGS/VobSub) are skipped — the server can't deliver them as VTT. These are
    /// fetched + rendered client-side to dodge the in-manifest WebVTT drift.
    private static func subtitleStreamURLs(
        streams: [MediaStreamInfo],
        itemID: String,
        mediaSourceID: String,
        client: JellyfinPlaybackClient
    ) -> [Int: URL] {
        var map: [Int: URL] = [:]
        for stream in streams where stream.kind == .subtitle && !stream.isImageSubtitle {
            if let url = client.subtitleStreamURL(
                itemID: itemID,
                mediaSourceID: mediaSourceID,
                streamIndex: stream.index,
                format: "vtt"
            ) {
                map[stream.index] = url
            }
        }
        return map
    }

    /// Parses the `TranscodeReasons` query item the server appends to the
    /// transcoding URL (comma-separated). Reads the source's `transcodingURL`
    /// string directly — the authoritative value, before the client rebuilds the
    /// final URL. Empty for direct-play or when the server didn't include it —
    /// best-effort diagnostic, never load-bearing.
    private static func transcodeReasons(from transcodingURL: String?) -> [String] {
        guard let transcodingURL,
              let raw = URLComponents(string: transcodingURL)?
                .queryItems?.first(where: { $0.name == "TranscodeReasons" })?.value
        else { return [] }
        return raw
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Maps the source's `MediaStream`s to neutral `MediaStreamInfo`, dropping
    /// streams without an index (no stable identity / not server-selectable).
    private static func mediaStreamInfos(from source: MediaSourceInfo) -> [MediaStreamInfo] {
        (source.mediaStreams ?? []).compactMap { stream in
            guard let index = stream.index else { return nil }
            return MediaStreamInfo(
                index: index,
                kind: kind(from: stream.type),
                displayTitle: stream.displayTitle,
                language: stream.language,
                codec: stream.codec,
                channels: stream.channels,
                isExternal: stream.isExternal ?? false,
                isForced: stream.isForced ?? false,
                isDefault: stream.isDefault ?? false,
                profile: stream.profile,
                bitDepth: stream.bitDepth,
                width: stream.width,
                height: stream.height,
                videoRange: stream.videoRange?.rawValue,
                videoRangeType: stream.videoRangeType?.rawValue,
                colorSpace: stream.colorSpace,
                bitRate: stream.bitRate,
                frameRate: Self.roundedFrameRate(stream.realFrameRate ?? stream.averageFrameRate),
                sampleRate: stream.sampleRate,
                subtitleDeliveryMethod: stream.deliveryMethod?.rawValue
            )
        }
    }

    /// Rounds a frame rate to 3 decimals so 23.976 / 59.94 display cleanly
    /// (a raw `Float`→`Double` widen leaves 23.97599983…).
    private static func roundedFrameRate(_ value: Float?) -> Double? {
        guard let value else { return nil }
        return (Double(value) * 1000).rounded() / 1000
    }

    private static func kind(from type: MediaStreamType?) -> MediaStreamInfo.Kind {
        switch type {
        case .video: return .video
        case .audio: return .audio
        case .subtitle: return .subtitle
        default: return .other
        }
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
