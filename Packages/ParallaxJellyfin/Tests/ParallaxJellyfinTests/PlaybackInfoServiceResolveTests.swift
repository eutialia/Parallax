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
        var video = MediaStream()
        video.type = .video
        video.codec = "hevc"
        source.mediaStreams = [video]
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
