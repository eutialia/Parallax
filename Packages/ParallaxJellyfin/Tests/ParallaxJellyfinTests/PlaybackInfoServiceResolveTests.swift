import Foundation
import CoreMedia
import Testing
import JellyfinAPI
import ParallaxCore
@testable import ParallaxJellyfin

@Suite("PlaybackInfoService — resolve")
struct PlaybackInfoServiceResolveTests {
    private func caps() -> DeviceCapabilities {
        DeviceCapabilities(
            supportedVideoCodecs: [.h264, .hevc],
            supportedAudioCodecs: [.aac, .ac3, .eac3, .mp3],
            supportedContainers: [.mp4, .mov, .hls],
            hdr: .none,
            maxResolution: .uhd4K,
            maxBitrate: .megabits(120),
            audioOutput: .stereo,
            preferredSubtitleFormats: [.vtt, .srt]
        )
    }

    private func directPlaySource() -> MediaSourceInfo {
        var source = MediaSourceInfo()
        source.id = "ms-1"
        source.container = "mp4"
        source.runTimeTicks = 1_000_000_000  // 100s
        source.isSupportsDirectStream = true
        source.transcodingURL = nil
        var video = MediaStream()
        video.type = .video
        video.codec = "h264"
        var audio = MediaStream()
        audio.type = .audio
        audio.codec = "aac"
        source.mediaStreams = [video, audio]
        return source
    }

    private func transcodeSource() -> MediaSourceInfo {
        var source = MediaSourceInfo()
        source.id = "ms-2"
        source.container = "mkv"
        source.runTimeTicks = 1_000_000_000
        source.transcodingURL = "/videos/item-1/master.m3u8?api_key=tok-1&PlaySessionId=ps-1"
        source.defaultAudioStreamIndex = 3
        source.defaultSubtitleStreamIndex = 1
        var video = MediaStream()
        video.type = .video
        video.index = 0
        video.codec = "hevc"
        video.profile = "Main 10"
        video.bitDepth = 10
        video.width = 3840
        video.height = 2160
        video.videoRange = .hdr
        video.videoRangeType = .hdr10
        video.colorSpace = "bt2020nc"
        video.bitRate = 18_200_000
        video.realFrameRate = 23.976
        var audio = MediaStream()
        audio.type = .audio
        audio.index = 3
        audio.codec = "truehd"
        audio.channels = 8
        audio.sampleRate = 48_000
        audio.bitRate = 4_500_000
        audio.displayTitle = "English - TrueHD 7.1"
        audio.language = "eng"
        audio.isDefault = true
        var subtitle = MediaStream()
        subtitle.type = .subtitle
        subtitle.index = 1
        subtitle.codec = "subrip"
        subtitle.displayTitle = "Chinese"
        subtitle.language = "zho"
        subtitle.deliveryMethod = .hls
        source.mediaStreams = [video, audio, subtitle]
        return source
    }

    /// A transcode whose URL carries `TranscodeReasons` (the server tells us *why*
    /// it's transcoding) — parsed onto `ResolvedPlayback.transcodeReasons`.
    private func transcodeSourceWithReasons() -> MediaSourceInfo {
        var source = transcodeSource()
        source.transcodingURL =
            "/videos/item-1/master.m3u8?api_key=tok-1&PlaySessionId=ps-1&TranscodeReasons=ContainerNotSupported,AudioCodecNotSupported"
        return source
    }

    private func makeService(source: MediaSourceInfo) -> (PlaybackInfoService, FakeJellyfinPlaybackClient) {
        let fake = FakeJellyfinPlaybackClient()
        var response = PlaybackInfoResponse()
        response.mediaSources = [source]
        response.playSessionID = "ps-1"
        fake.playbackInfoResult = .success(response)
        return (PlaybackInfoService(client: fake), fake)
    }

    @Test("Non-transcode source resolves to .directPlay with a static (range-seekable) stream URL")
    func directBranch() async throws {
        let (service, fake) = makeService(source: directPlaySource())
        let resolved = try await service.resolve(
            item: ItemID(rawValue: "item-1"),
            capabilities: caps(),
            startTime: nil
        )
        // AVPlayer requires HTTP byte-range support for progressive playback,
        // which Jellyfin's raw-file (static=true) direct-play endpoint provides
        // but its on-the-fly remux (static=false) does not — the remux answers
        // 200/chunked, which AVFoundation rejects (-12939 / -11850). A
        // non-transcode source is AVKit-native per our device profile, so we
        // direct-play the raw, seekable file.
        #expect(resolved.method == .directPlay)
        #expect(fake.streamURLRequests.first?.isStatic == true)
        #expect(resolved.mediaSourceID == "ms-1")
        #expect(resolved.playSessionID == "ps-1")
        #expect(resolved.container == .mp4)
        #expect(resolved.videoCodec == .h264)
        #expect(resolved.audioCodec == .aac)
        #expect(resolved.url.query?.contains("api_key=") == true)
        #expect(fake.streamURLRequests.first?.mediaSourceID == "ms-1")
        #expect(fake.transcodePaths.isEmpty)
    }

    @Test("Server transcodingURL forces .transcode regardless of profile")
    func transcodeBranch() async throws {
        let (service, fake) = makeService(source: transcodeSource())
        let resolved = try await service.resolve(
            item: ItemID(rawValue: "item-1"),
            capabilities: caps(),
            startTime: nil
        )
        #expect(resolved.method == .transcode)
        #expect(resolved.url.query?.contains("api_key=") == true)
        #expect(resolved.url.absoluteString.contains("master.m3u8"))
        // It resolved the server-provided transcodingURL, not a stream URL.
        #expect(fake.transcodePaths.first == "/videos/item-1/master.m3u8?api_key=tok-1&PlaySessionId=ps-1")
        #expect(fake.streamURLRequests.isEmpty)
    }

    @Test("Explicit audio/subtitle stream indices are forwarded to the PlaybackInfo request")
    func streamIndicesForwarded() async throws {
        let (service, fake) = makeService(source: transcodeSource())
        _ = try await service.resolve(
            item: ItemID(rawValue: "item-1"),
            capabilities: caps(),
            startTime: CMTime(seconds: 600, preferredTimescale: 600),
            audioStreamIndex: 4,
            subtitleStreamIndex: 7
        )
        #expect(fake.playbackInfoCalls.first?.audioStreamIndex == 4)
        #expect(fake.playbackInfoCalls.first?.subtitleStreamIndex == 7)
        #expect(fake.playbackInfoCalls.first?.startTimeTicks == 6_000_000_000)
    }

    @Test("Omitted stream indices default to nil (server picks)")
    func streamIndicesDefaultNil() async throws {
        let (service, fake) = makeService(source: directPlaySource())
        _ = try await service.resolve(
            item: ItemID(rawValue: "item-1"),
            capabilities: caps(),
            startTime: nil
        )
        #expect(fake.playbackInfoCalls.first?.audioStreamIndex == nil)
        #expect(fake.playbackInfoCalls.first?.subtitleStreamIndex == nil)
    }

    @Test("Source media streams + default indices are mapped to ResolvedPlayback")
    func mediaStreamsMapped() async throws {
        let (service, _) = makeService(source: transcodeSource())
        let resolved = try await service.resolve(
            item: ItemID(rawValue: "item-1"),
            capabilities: caps(),
            startTime: nil
        )
        #expect(resolved.mediaStreams.count == 3)
        #expect(resolved.defaultAudioStreamIndex == 3)
        #expect(resolved.defaultSubtitleStreamIndex == 1)

        let audio = resolved.mediaStreams.first { $0.kind == .audio }
        #expect(audio?.index == 3)
        #expect(audio?.displayTitle == "English - TrueHD 7.1")
        #expect(audio?.language == "eng")
        #expect(audio?.channels == 8)
        #expect(audio?.isDefault == true)
        #expect(audio?.sampleRate == 48_000)
        #expect(audio?.bitRate == 4_500_000)

        let subtitle = resolved.mediaStreams.first { $0.kind == .subtitle }
        #expect(subtitle?.index == 1)
        #expect(subtitle?.displayTitle == "Chinese")
        #expect(subtitle?.subtitleDeliveryMethod == "Hls")
    }

    @Test("Sidecar VTT URLs are built for text subtitles (copyTimestamps + api_key) and exclude image subs")
    func subtitleSidecarURLsBuilt() async throws {
        var source = transcodeSource()          // text sub: index 1, subrip
        var pgs = MediaStream()                  // image sub: index 2, pgssub
        pgs.type = .subtitle
        pgs.index = 2
        pgs.codec = "pgssub"
        source.mediaStreams?.append(pgs)
        let (service, _) = makeService(source: source)

        let resolved = try await service.resolve(
            item: ItemID(rawValue: "item-1"),
            capabilities: caps(),
            startTime: nil
        )

        #expect(resolved.subtitleStreamURLs.count == 1)
        #expect(resolved.subtitleStreamURLs[2] == nil)          // image sub excluded
        let url = try #require(resolved.subtitleStreamURLs[1]?.absoluteString)
        #expect(url.contains("/Subtitles/1/Stream.vtt"))
        #expect(url.contains("copyTimestamps=true"))
        #expect(url.contains("api_key="))
    }

    @Test("Video stream's HDR / resolution / bit-depth debug fields are mapped")
    func videoDebugFieldsMapped() async throws {
        let (service, _) = makeService(source: transcodeSource())
        let resolved = try await service.resolve(
            item: ItemID(rawValue: "item-1"),
            capabilities: caps(),
            startTime: nil
        )
        let video = resolved.mediaStreams.first { $0.kind == .video }
        #expect(video?.profile == "Main 10")
        #expect(video?.bitDepth == 10)
        #expect(video?.width == 3840)
        #expect(video?.height == 2160)
        #expect(video?.videoRange == "HDR")
        #expect(video?.videoRangeType == "HDR10")
        #expect(video?.colorSpace == "bt2020nc")
        #expect(video?.bitRate == 18_200_000)
        #expect(video?.frameRate == 23.976)
    }

    @Test("TranscodeReasons in the transcoding URL are parsed onto ResolvedPlayback")
    func transcodeReasonsParsed() async throws {
        let (service, _) = makeService(source: transcodeSourceWithReasons())
        let resolved = try await service.resolve(
            item: ItemID(rawValue: "item-1"),
            capabilities: caps(),
            startTime: nil
        )
        #expect(resolved.transcodeReasons == ["ContainerNotSupported", "AudioCodecNotSupported"])
    }

    @Test("Direct-play has no transcode reasons")
    func directPlayNoTranscodeReasons() async throws {
        let (service, _) = makeService(source: directPlaySource())
        let resolved = try await service.resolve(
            item: ItemID(rawValue: "item-1"),
            capabilities: caps(),
            startTime: nil
        )
        #expect(resolved.transcodeReasons.isEmpty)
    }

    @Test("startTime is converted to ticks (seconds * 10_000_000) for the POST and echoed back")
    func tickConversion() async throws {
        let (service, fake) = makeService(source: directPlaySource())
        let resolved = try await service.resolve(
            item: ItemID(rawValue: "item-1"),
            capabilities: caps(),
            startTime: CMTime(seconds: 12, preferredTimescale: 600)
        )
        #expect(fake.playbackInfoCalls.first?.startTimeTicks == 120_000_000)
        #expect(resolved.startTime == CMTime(seconds: 12, preferredTimescale: 600))
    }

    @Test("Runtime ticks from the chosen source map to ResolvedPlayback.runtime")
    func runtimeMapped() async throws {
        let (service, _) = makeService(source: directPlaySource())
        let resolved = try await service.resolve(
            item: ItemID(rawValue: "item-1"),
            capabilities: caps(),
            startTime: nil
        )
        #expect(resolved.runtime == CMTime(seconds: 100, preferredTimescale: 10_000_000))
    }

    @Test("Empty media sources throws an AppError")
    func emptySourcesThrows() async {
        let fake = FakeJellyfinPlaybackClient()
        var response = PlaybackInfoResponse()
        response.mediaSources = []
        response.playSessionID = "ps-1"
        fake.playbackInfoResult = .success(response)
        let service = PlaybackInfoService(client: fake)
        await #expect(throws: AppError.self) {
            _ = try await service.resolve(
                item: ItemID(rawValue: "item-1"),
                capabilities: caps(),
                startTime: nil
            )
        }
    }
}
