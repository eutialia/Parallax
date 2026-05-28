import Foundation
import Testing
import ParallaxCore
@testable import ParallaxPlayback

// Helpers to build PlaybackHints concisely in matrix tests.
private extension PlaybackHints {
    static func avKitHappy(
        scheme: String = "https",
        container: Container = .mp4,
        video: VideoCodec = .h264,
        audio: AudioCodec = .aac
    ) -> PlaybackHints {
        PlaybackHints(scheme: scheme, container: container, videoCodec: video, audioCodec: audio, subtitleFormats: [])
    }

    static func with(
        scheme: String? = "https",
        container: Container? = .mp4,
        video: VideoCodec? = .h264,
        audio: AudioCodec? = .aac,
        subtitles: [SubtitleFormat] = []
    ) -> PlaybackHints {
        PlaybackHints(scheme: scheme, container: container, videoCodec: video, audioCodec: audio, subtitleFormats: subtitles)
    }
}

@Suite("EngineSelector matrix")
struct EngineSelectorTests {

    // MARK: — AVKit happy paths

    @Test("mp4/h264/aac over https → .avKit")
    func mp4H264AAC() {
        let hints = PlaybackHints.avKitHappy()
        #expect(EngineSelector.select(hints: hints) == .avKit)
    }

    @Test("mp4/hevc/eac3 → .avKit (HEVC + Dolby Digital Plus are AVPlayer-playable)")
    func mp4HevcEAC3() {
        let hints = PlaybackHints.avKitHappy(video: .hevc, audio: .eac3)
        #expect(EngineSelector.select(hints: hints) == .avKit)
    }

    @Test("mov/h264/ac3 → .avKit")
    func movH264AC3() {
        let hints = PlaybackHints.avKitHappy(container: .mov, audio: .ac3)
        #expect(EngineSelector.select(hints: hints) == .avKit)
    }

    @Test("hls/h264/aac → .avKit (HLS is AVPlayer's native format)")
    func hlsH264AAC() {
        let hints = PlaybackHints.avKitHappy(container: .hls)
        #expect(EngineSelector.select(hints: hints) == .avKit)
    }

    @Test("mp4/h264/mp3 → .avKit")
    func mp4H264MP3() {
        let hints = PlaybackHints.avKitHappy(audio: .mp3)
        #expect(EngineSelector.select(hints: hints) == .avKit)
    }

    @Test("all-nil hints → .avKit (no disqualifying signal; transcode produces HLS)")
    func allNilHints() {
        let hints = PlaybackHints(scheme: nil, container: nil, videoCodec: nil, audioCodec: nil, subtitleFormats: [])
        #expect(EngineSelector.select(hints: hints) == .avKit)
    }

    @Test("nil container with AVKit-playable codec → .avKit")
    func nilContainerAVKitCodec() {
        let hints = PlaybackHints.with(container: nil, video: .h264, audio: .aac)
        #expect(EngineSelector.select(hints: hints) == .avKit)
    }

    @Test("vtt subtitles alone do not trigger .vlcKit")
    func vttSubtitleAVKit() {
        let hints = PlaybackHints.with(subtitles: [.vtt])
        #expect(EngineSelector.select(hints: hints) == .avKit)
    }

    @Test("srt subtitles alone do not trigger .vlcKit")
    func srtSubtitleAVKit() {
        let hints = PlaybackHints.with(subtitles: [.srt])
        #expect(EngineSelector.select(hints: hints) == .avKit)
    }

    // MARK: — VLCKit routing: smb scheme

    @Test("smb scheme → .vlcKit regardless of codec/container")
    func smbSchemeVLC() {
        let hints = PlaybackHints.with(scheme: "smb", container: .mp4, video: .h264, audio: .aac)
        #expect(EngineSelector.select(hints: hints) == .vlcKit)
    }

    @Test("smb scheme + mkv/hevc still → .vlcKit (scheme wins)")
    func smbSchemeWithMKV() {
        let hints = PlaybackHints.with(scheme: "smb", container: .mkv, video: .hevc, audio: .dts)
        #expect(EngineSelector.select(hints: hints) == .vlcKit)
    }

    // MARK: — VLCKit routing: ASS subtitles

    @Test("ASS subtitle format → .vlcKit")
    func assSubtitleVLC() {
        let hints = PlaybackHints.with(subtitles: [.ass])
        #expect(EngineSelector.select(hints: hints) == .vlcKit)
    }

    @Test("ASS + VTT mix → .vlcKit (ASS is disqualifying)")
    func assAndVTTSubtitleVLC() {
        let hints = PlaybackHints.with(subtitles: [.vtt, .ass])
        #expect(EngineSelector.select(hints: hints) == .vlcKit)
    }

    @Test("PGS subtitle → .vlcKit (image-based, not AVPlayer-renderable)")
    func pgsSubtitleVLC() {
        let hints = PlaybackHints.with(subtitles: [.pgs])
        #expect(EngineSelector.select(hints: hints) == .vlcKit)
    }

    @Test("VobSub subtitle → .vlcKit (image-based, not AVPlayer-renderable)")
    func vobSubSubtitleVLC() {
        let hints = PlaybackHints.with(subtitles: [.vobsub])
        #expect(EngineSelector.select(hints: hints) == .vlcKit)
    }

    // MARK: — VLCKit routing: non-AVPlayer container

    @Test("mkv container → .vlcKit")
    func mkvContainerVLC() {
        let hints = PlaybackHints.with(container: .mkv, video: .h264, audio: .aac)
        #expect(EngineSelector.select(hints: hints) == .vlcKit)
    }

    @Test("webm container → .vlcKit")
    func webmContainerVLC() {
        let hints = PlaybackHints.with(container: .webm, video: .vp9, audio: .opus)
        #expect(EngineSelector.select(hints: hints) == .vlcKit)
    }

    @Test("ts container → .vlcKit (raw MPEG-TS without HLS envelope)")
    func tsContainerVLC() {
        let hints = PlaybackHints.with(container: .ts, video: .h264, audio: .aac)
        #expect(EngineSelector.select(hints: hints) == .vlcKit)
    }

    @Test("flac container → .vlcKit")
    func flacContainerVLC() {
        let hints = PlaybackHints.with(container: .flac, video: nil, audio: .flac)
        #expect(EngineSelector.select(hints: hints) == .vlcKit)
    }

    // MARK: — VLCKit routing: non-AVPlayer video codec

    @Test("AV1 video codec → .vlcKit")
    func av1VideoCodecVLC() {
        let hints = PlaybackHints.with(container: .mp4, video: .av1, audio: .aac)
        #expect(EngineSelector.select(hints: hints) == .vlcKit)
    }

    @Test("VP9 video codec → .vlcKit")
    func vp9VideoCodecVLC() {
        let hints = PlaybackHints.with(container: .mp4, video: .vp9, audio: .aac)
        #expect(EngineSelector.select(hints: hints) == .vlcKit)
    }

    // MARK: — VLCKit routing: non-AVPlayer audio codec

    @Test("DTS audio codec → .vlcKit")
    func dtsAudioCodecVLC() {
        let hints = PlaybackHints.with(container: .mp4, video: .h264, audio: .dts)
        #expect(EngineSelector.select(hints: hints) == .vlcKit)
    }

    @Test("TrueHD audio codec → .vlcKit")
    func trueHDAudioCodecVLC() {
        let hints = PlaybackHints.with(container: .mp4, video: .h264, audio: .trueHD)
        #expect(EngineSelector.select(hints: hints) == .vlcKit)
    }

    @Test("FLAC audio codec → .vlcKit")
    func flacAudioCodecVLC() {
        let hints = PlaybackHints.with(container: .mp4, video: .h264, audio: .flac)
        #expect(EngineSelector.select(hints: hints) == .vlcKit)
    }

    @Test("Opus audio codec → .vlcKit")
    func opusAudioCodecVLC() {
        let hints = PlaybackHints.with(container: .mp4, video: .h264, audio: .opus)
        #expect(EngineSelector.select(hints: hints) == .vlcKit)
    }

    // MARK: — Priority order verification

    @Test("smb scheme is checked before subtitle format (scheme wins)")
    func smbBeforeSubtitle() {
        // Even with only VTT (normally avKit), smb still routes to vlcKit
        let hints = PlaybackHints(scheme: "smb", container: .mp4, videoCodec: .h264, audioCodec: .aac, subtitleFormats: [.vtt])
        #expect(EngineSelector.select(hints: hints) == .vlcKit)
    }

    @Test("Scheme-check fires before container-check")
    func smbBeforeContainerCheck() {
        // smb + non-AVKit container: scheme is checked first, result is same (.vlcKit)
        let hints = PlaybackHints(scheme: "smb", container: .mkv, videoCodec: .h264, audioCodec: .aac, subtitleFormats: [])
        #expect(EngineSelector.select(hints: hints) == .vlcKit)
    }
}
