import Foundation
import Testing
import JellyfinAPI
import ParallaxCore
@testable import ParallaxJellyfin

@Suite("DeviceProfile translation")
struct DeviceProfileTranslatorTests {

    // MARK: — Fixtures

    private func avKitOnlyCaps() -> DeviceCapabilities {
        DeviceCapabilities(
            supportedVideoCodecs: [.h264, .hevc],
            supportedAudioCodecs: [.aac, .ac3, .eac3, .mp3],
            supportedContainers: [.mp4, .mov],
            hdr: .none,
            maxResolution: .uhd4K,
            maxBitrate: .megabits(120),
            audioOutput: .stereo,
            preferredSubtitleFormats: [.vtt, .srt],
            softwareVideoCodecs: [],
            softwareAudioCodecs: [],
            softwareContainers: []
        )
    }

    private func tieredCaps() -> DeviceCapabilities {
        DeviceCapabilities(
            supportedVideoCodecs: [.h264, .hevc],
            supportedAudioCodecs: [.aac, .ac3, .eac3, .mp3],
            supportedContainers: [.mp4, .mov],
            hdr: .none,
            maxResolution: .uhd4K,
            maxBitrate: .megabits(120),
            audioOutput: .stereo,
            preferredSubtitleFormats: [.vtt, .srt],
            softwareVideoCodecs: [.vc1, .mpeg2video, .vp9, .av1],
            softwareAudioCodecs: [.dts, .trueHD, .flac, .opus],
            softwareContainers: [.mkv, .webm, .avi, .ts, .mp3, .flac]
        )
    }

    /// Mirrors DeviceProfileBuilder.build(): supportedContainers INCLUDES .hls.
    private func realBuildCaps() -> DeviceCapabilities {
        DeviceCapabilities(
            supportedVideoCodecs: [.h264, .hevc],
            supportedAudioCodecs: [.aac, .ac3, .eac3, .mp3],
            supportedContainers: [.mp4, .mov, .hls],
            hdr: .none,
            maxResolution: .uhd4K,
            maxBitrate: .megabits(120),
            audioOutput: .stereo,
            preferredSubtitleFormats: [.vtt, .srt],
            softwareVideoCodecs: [.vc1, .mpeg2video, .vp9, .av1],
            softwareAudioCodecs: [.dts, .trueHD, .flac, .opus],
            softwareContainers: [.mkv, .webm, .avi, .ts, .mp3, .flac]
        )
    }

    // MARK: — AVKit DirectPlay tier

    @Test("AVKit DirectPlay profile advertises mp4 and mov containers")
    func avKitDirectPlayContainers() {
        let profile = DeviceProfileTranslator.deviceProfile(from: tieredCaps())
        let direct = profile.directPlayProfiles ?? []
        let avKitEntry = direct.first { ($0.container ?? "").contains("mp4") && !($0.container ?? "").contains("mkv") }
        #expect(avKitEntry != nil, "No AVKit DirectPlay entry with container containing mp4")
        #expect(avKitEntry?.type == .video)
        // Containers are sorted and joined — verify via set decomposition
        let parts = Set((avKitEntry?.container ?? "").split(separator: ",").map(String.init))
        #expect(parts == ["mp4", "mov"])
    }

    @Test("AVKit DirectPlay profile lists h264,hevc as video codecs")
    func avKitDirectPlayVideoCodecs() {
        let profile = DeviceProfileTranslator.deviceProfile(from: tieredCaps())
        let direct = profile.directPlayProfiles ?? []
        let avKitEntry = direct.first { ($0.container ?? "").contains("mp4") && !($0.container ?? "").contains("mkv") }
        let codecs = avKitEntry?.videoCodec ?? ""
        let parts = Set(codecs.split(separator: ",").map(String.init))
        #expect(parts == ["h264", "hevc"])
    }

    @Test("AVKit DirectPlay profile lists aac,ac3,eac3,mp3 as audio codecs")
    func avKitDirectPlayAudioCodecs() {
        let profile = DeviceProfileTranslator.deviceProfile(from: tieredCaps())
        let direct = profile.directPlayProfiles ?? []
        let avKitEntry = direct.first { ($0.container ?? "").contains("mp4") && !($0.container ?? "").contains("mkv") }
        let codecs = avKitEntry?.audioCodec ?? ""
        let parts = Set(codecs.split(separator: ",").map(String.init))
        #expect(parts == ["aac", "ac3", "eac3", "mp3"])
    }

    // MARK: — VLC DirectPlay tier

    @Test("VLC DirectPlay profile exists when softwareVideoCodecs is non-empty")
    func vlcDirectPlayExists() {
        let profile = DeviceProfileTranslator.deviceProfile(from: tieredCaps())
        let direct = profile.directPlayProfiles ?? []
        let vlcEntry = direct.first { ($0.container ?? "").contains("mkv") }
        #expect(vlcEntry != nil, "No VLC DirectPlay entry containing mkv")
        #expect(vlcEntry?.type == .video)
    }

    @Test("VLC DirectPlay video codecs exclude h264 and hevc")
    func vlcDirectPlayExcludesAVKitVideoCodecs() {
        let profile = DeviceProfileTranslator.deviceProfile(from: tieredCaps())
        let direct = profile.directPlayProfiles ?? []
        let vlcEntry = direct.first { ($0.container ?? "").contains("mkv") }
        let codecs = Set((vlcEntry?.videoCodec ?? "").split(separator: ",").map(String.init))
        #expect(!codecs.contains("h264"),
            "h264 must not appear in the VLC DirectPlay tier — premium MKV must remux to AVKit")
        #expect(!codecs.contains("hevc"),
            "hevc must not appear in the VLC DirectPlay tier — premium MKV must remux to AVKit")
    }

    @Test("VLC DirectPlay video codecs contain vc1, mpeg2video, vp9, av1")
    func vlcDirectPlayVideoCodecs() {
        let profile = DeviceProfileTranslator.deviceProfile(from: tieredCaps())
        let direct = profile.directPlayProfiles ?? []
        let vlcEntry = direct.first { ($0.container ?? "").contains("mkv") }
        let codecs = Set((vlcEntry?.videoCodec ?? "").split(separator: ",").map(String.init))
        #expect(codecs.contains("vc1"))
        #expect(codecs.contains("mpeg2video"))
        #expect(codecs.contains("vp9"))
        #expect(codecs.contains("av1"))
    }

    @Test("VLC DirectPlay audio codecs include dts, trueHD, flac, opus plus AVKit audio")
    func vlcDirectPlayAudioCodecs() {
        let profile = DeviceProfileTranslator.deviceProfile(from: tieredCaps())
        let direct = profile.directPlayProfiles ?? []
        let vlcEntry = direct.first { ($0.container ?? "").contains("mkv") }
        let codecs = Set((vlcEntry?.audioCodec ?? "").split(separator: ",").map(String.init))
        #expect(codecs.contains("dts"))
        // AudioCodec.trueHD.rawValue == "trueHD" (capital H)
        #expect(codecs.contains("trueHD"))
        #expect(codecs.contains("flac"))
        #expect(codecs.contains("opus"))
        // AVKit audio is also allowed in VLC-routed files
        #expect(codecs.contains("aac"))
        #expect(codecs.contains("eac3"))
    }

    @Test("VLC DirectPlay container string includes mkv, webm, avi, ts")
    func vlcDirectPlayContainers() {
        let profile = DeviceProfileTranslator.deviceProfile(from: tieredCaps())
        let direct = profile.directPlayProfiles ?? []
        let vlcEntry = direct.first { ($0.container ?? "").contains("mkv") }
        let containers = Set((vlcEntry?.container ?? "").split(separator: ",").map(String.init))
        #expect(containers.contains("mkv"))
        #expect(containers.contains("webm"))
        #expect(containers.contains("avi"))
        #expect(containers.contains("ts"))
    }

    @Test("No VLC DirectPlay entry when softwareVideoCodecs is empty (avKit-only caps)")
    func noVLCTierWhenSoftwareEmpty() {
        let profile = DeviceProfileTranslator.deviceProfile(from: avKitOnlyCaps())
        let direct = profile.directPlayProfiles ?? []
        let vlcEntry = direct.first { ($0.container ?? "").contains("mkv") }
        #expect(vlcEntry == nil,
            "VLC DirectPlay entry must not appear when softwareVideoCodecs is empty")
    }

    @Test("Total DirectPlay count is 1 for avKit-only caps and 2 for tiered caps")
    func directPlayCounts() {
        let avKitProfile = DeviceProfileTranslator.deviceProfile(from: avKitOnlyCaps())
        let tieredProfile = DeviceProfileTranslator.deviceProfile(from: tieredCaps())
        #expect((avKitProfile.directPlayProfiles ?? []).count == 1)
        #expect((tieredProfile.directPlayProfiles ?? []).count == 2)
    }

    // MARK: — .hls exclusion (delivery format, not a source container)

    @Test("AVKit DirectPlay container string excludes hls (delivery format, not a source container)")
    func avKitDirectPlayExcludesHLS() {
        let profile = DeviceProfileTranslator.deviceProfile(from: realBuildCaps())
        let direct = profile.directPlayProfiles ?? []
        let avKitEntry = direct.first { ($0.container ?? "").contains("mp4") && !($0.container ?? "").contains("mkv") }
        let parts = Set((avKitEntry?.container ?? "").split(separator: ",").map(String.init))
        #expect(!parts.contains("hls"))
        #expect(parts == ["mp4", "mov"])
    }

    @Test("VLC DirectPlay container string excludes hls")
    func vlcDirectPlayExcludesHLS() {
        let profile = DeviceProfileTranslator.deviceProfile(from: realBuildCaps())
        let direct = profile.directPlayProfiles ?? []
        let vlcEntry = direct.first { ($0.container ?? "").contains("mkv") }
        let parts = Set((vlcEntry?.container ?? "").split(separator: ",").map(String.init))
        #expect(!parts.contains("hls"))
    }

    // MARK: — TranscodingProfile

    @Test("TranscodingProfile targets HLS mp4; subtitles are NOT in the manifest (client renders sidecar VTT)")
    func transcoding() {
        let profile = DeviceProfileTranslator.deviceProfile(from: tieredCaps())
        let trans = profile.transcodingProfiles ?? []
        #expect(trans.count == 1)
        #expect(trans.first?.protocol == .hls)
        #expect(trans.first?.container == "mp4")
        #expect(trans.first?.type == .video)
        #expect(trans.first?.videoCodec == "h264,hevc")
        #expect(trans.first?.audioCodec == "aac,ac3,eac3")
        // Always request up to 7.1 (8ch); the OS downmixes/spatializes per route.
        // Without this Jellyfin defaults the transcode to 5.1 and downmixes 7.1 sources.
        #expect(trans.first?.maxAudioChannels == "8")
        // In-manifest WebVTT mis-times on fMP4 (jellyfin#16647); we fetch a sidecar.
        #expect(trans.first?.enableSubtitlesInManifest == false)
        // Startup-latency knobs (Swiftfin-matched): on the remux path the
        // segmenter can't force keyframes, so without BreakOnNonKeyFrames the
        // playlist waits on the source's long-GOP keyframes; MinSegments=2
        // serves it as soon as AVPlayer has enough to start.
        #expect(trans.first?.isBreakOnNonKeyFrames == true)
        #expect(trans.first?.minSegments == 2)
    }

    // MARK: — SubtitleProfiles

    @Test("SubtitleProfiles deliver VTT external only — never in-manifest HLS (jellyfin#16647)")
    func vttSubtitleProfiles() {
        let profile = DeviceProfileTranslator.deviceProfile(from: tieredCaps())
        let subs = profile.subtitleProfiles ?? []
        #expect(subs.contains { $0.format == "vtt" && $0.method == .external })
        // No subtitle may be delivered in the HLS manifest: an in-manifest WebVTT
        // mis-times on fMP4 segments and AVPlayer auto-renders it under our sidecar.
        #expect(!subs.contains { $0.method == .hls })
    }

    @Test("SubtitleProfiles include SRT external for VLC sidecar delivery")
    func srtExternalSubtitleProfile() {
        let profile = DeviceProfileTranslator.deviceProfile(from: tieredCaps())
        let subs = profile.subtitleProfiles ?? []
        #expect(subs.contains { $0.format == "srt" && $0.method == .external })
    }

    @Test("SubtitleProfiles include ASS external for VLC libass rendering")
    func assExternalSubtitleProfile() {
        let profile = DeviceProfileTranslator.deviceProfile(from: tieredCaps())
        let subs = profile.subtitleProfiles ?? []
        #expect(subs.contains { $0.format == "ass" && $0.method == .external })
    }

    @Test("SubtitleProfiles include PGS external for VLC image-sub rendering")
    func pgsExternalSubtitleProfile() {
        let profile = DeviceProfileTranslator.deviceProfile(from: tieredCaps())
        let subs = profile.subtitleProfiles ?? []
        #expect(subs.contains { $0.format == "pgs" && $0.method == .external })
    }

    // MARK: — CodecProfiles (unchanged)

    @Test("CodecProfile gates H.264 to 8-bit 4:2:0 profiles (excludes High 10)")
    func h264ProfileGuard() {
        let profile = DeviceProfileTranslator.deviceProfile(from: tieredCaps())
        let codecs = profile.codecProfiles ?? []
        let h264 = codecs.first { $0.codec == "h264" && $0.type == .video }
        let condition = h264?.conditions?.first { $0.property == .videoProfile }
        #expect(condition?.condition == .equalsAny)
        #expect(condition?.value == "high|main|baseline|constrained baseline")
    }

    @Test("CodecProfile constrains HEVC bit depth to ≤ 10")
    func hevcBitDepthGuard() {
        let profile = DeviceProfileTranslator.deviceProfile(from: tieredCaps())
        let codecs = profile.codecProfiles ?? []
        let hevc = codecs.first { $0.codec == "hevc" && $0.type == .video }
        let condition = hevc?.conditions?.first { $0.property == .videoBitDepth }
        #expect(condition?.condition == .lessThanEqual)
        #expect(condition?.value == "10")
    }

    @Test("HEVC range gate is static: HDR bases + DV-with-fallback always pass (AVPlayer tone-maps on SDR displays), bare DOVI/DOVIWithEL never")
    func hevcRangeGateStatic() {
        // tieredCaps() declares hdr: .none — the whitelist must NOT shrink for
        // it: gating HDR10 on the probe forced an SDR-mode Apple TV into a 4K
        // server tone-map it couldn't sustain (endless buffering, -12889).
        let profile = DeviceProfileTranslator.deviceProfile(from: tieredCaps())
        let hevc = (profile.codecProfiles ?? []).first { $0.codec == "hevc" && $0.type == .video }
        let condition = hevc?.conditions?.first { $0.property == .videoRangeType }
        #expect(condition?.condition == .equalsAny)
        let entries = Set((condition?.value ?? "").split(separator: "|").map(String.init))
        for allowed in ["SDR", "HDR10", "HDR10Plus", "HLG", "DOVIWithSDR", "DOVIWithHDR10", "DOVIWithHDR10Plus", "DOVIWithHLG"] {
            #expect(entries.contains(allowed), "missing \(allowed)")
        }
        // The killers stay outside: no base layer AVPlayer can decode.
        #expect(!entries.contains("DOVI"))
        #expect(!entries.contains("DOVIWithEL"))
        #expect(!entries.contains("DOVIInvalid"))

        let h264 = (profile.codecProfiles ?? []).first { $0.codec == "h264" && $0.type == .video }
        let h264Range = h264?.conditions?.first { $0.property == .videoRangeType }
        #expect(h264Range?.value == "SDR|DOVIWithSDR")
    }

    // MARK: — Bitrate caps

    @Test("Bitrate caps are serialized from capabilities.maxBitrate")
    func serializesBitrateCap() {
        let profile = DeviceProfileTranslator.deviceProfile(from: tieredCaps())
        // tieredCaps() declares .megabits(120) → 120_000_000 bps on the wire.
        // nil would make Jellyfin apply an 8 Mbps default and re-encode 4K HDR.
        let expected = Int(Bitrate.megabits(120).rawValue)
        #expect(profile.maxStreamingBitrate == expected)
        #expect(profile.maxStaticBitrate == expected)
    }
}
