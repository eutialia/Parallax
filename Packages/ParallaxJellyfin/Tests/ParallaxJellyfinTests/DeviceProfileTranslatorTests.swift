import Foundation
import Testing
import JellyfinAPI
import ParallaxCore
@testable import ParallaxJellyfin

@Suite("DeviceProfile translation")
struct DeviceProfileTranslatorTests {
    private func sampleCaps(hdr: HDRSupport = .none) -> DeviceCapabilities {
        DeviceCapabilities(
            supportedVideoCodecs: [.h264, .hevc],
            supportedAudioCodecs: [.aac, .ac3, .eac3, .mp3],
            supportedContainers: [.mp4, .mov, .hls],
            hdr: hdr,
            maxResolution: .uhd4K,
            maxBitrate: .megabits(120),
            audioOutput: .stereo,
            preferredSubtitleFormats: [.vtt, .srt]
        )
    }

    @Test("DirectPlayProfile advertises the AVPlayer whitelist as video type")
    func directPlay() {
        let profile = DeviceProfileTranslator.deviceProfile(from: sampleCaps())
        let direct = profile.directPlayProfiles ?? []
        #expect(direct.count == 1)
        #expect(direct.first?.type == .video)
        #expect(direct.first?.container == "mp4,mov")
        #expect(direct.first?.videoCodec == "h264,hevc")
        #expect(direct.first?.audioCodec == "aac,ac3,eac3,mp3")
    }

    @Test("TranscodingProfile targets HLS with subtitles in the manifest")
    func transcoding() {
        let profile = DeviceProfileTranslator.deviceProfile(from: sampleCaps())
        let trans = profile.transcodingProfiles ?? []
        #expect(trans.count == 1)
        #expect(trans.first?.protocol == .hls)
        #expect(trans.first?.container == "mp4")
        #expect(trans.first?.type == .video)
        #expect(trans.first?.videoCodec == "h264,hevc")
        #expect(trans.first?.audioCodec == "aac,ac3,eac3")
        #expect(trans.first?.enableSubtitlesInManifest == true)
    }

    @Test("SubtitleProfile prefers WebVTT via HLS with an external fallback")
    func subtitles() {
        let profile = DeviceProfileTranslator.deviceProfile(from: sampleCaps())
        let subs = profile.subtitleProfiles ?? []
        #expect(subs.contains { $0.format == "vtt" && $0.method == .hls })
        #expect(subs.contains { $0.format == "vtt" && $0.method == .external })
    }

    @Test("CodecProfile constrains HEVC to video type")
    func codecProfile() {
        let profile = DeviceProfileTranslator.deviceProfile(from: sampleCaps())
        let codecs = profile.codecProfiles ?? []
        #expect(codecs.contains { $0.codec == "hevc" && $0.type == .video })
    }

    @Test("Bitrate caps are nil regardless of capabilities.maxBitrate")
    func noBitrateCap() {
        let profile = DeviceProfileTranslator.deviceProfile(from: sampleCaps())
        #expect(profile.maxStreamingBitrate == nil)
        #expect(profile.maxStaticBitrate == nil)
    }
}
