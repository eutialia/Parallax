import Foundation
import Testing
import JellyfinAPI
import ParallaxCore
@testable import ParallaxJellyfin

@Suite("DeviceProfile translation")
struct DeviceProfileTranslatorTests {

    // MARK: — Fixtures

    static let withoutAV1 = AVPlayerSupport(
        containers: [.mp4, .mov, .hls], videoCodecs: [.h264, .hevc], audioCodecs: [.aac, .ac3, .eac3]
    )
    static let withAV1 = AVPlayerSupport(
        containers: [.mp4, .mov, .hls],
        videoCodecs: [.h264, .hevc, .av1],
        audioCodecs: [.aac, .ac3, .eac3, .flac, .opus]
    )

    /// `hdr: .none` on purpose: several tests below assert the HEVC range whitelist does NOT
    /// shrink when the probe reports no HDR. The AVPlayer containers include `.hls`, as the probe
    /// reports them, which proves hls is stripped rather than never present.
    private func caps(
        avPlayer: AVPlayerSupport = DeviceProfileTranslatorTests.withoutAV1,
        hdr: HDRSupport = .none,
        maxResolution: Resolution = .uhd4K
    ) -> DeviceCapabilities {
        JellyfinFixtures.caps(avPlayer: avPlayer, hdr: hdr, maxResolution: maxResolution)
    }

    /// Dolby Vision hardware decode confirmed — the one signal that adds bare DOVI to the gate.
    private func dolbyVisionCaps(
        avPlayer: AVPlayerSupport = DeviceProfileTranslatorTests.withoutAV1, maxResolution: Resolution = .uhd4K
    ) -> DeviceCapabilities {
        caps(avPlayer: avPlayer, hdr: [.hdr10, .dolbyVision], maxResolution: maxResolution)
    }

    private func directPlayEntry(in profile: DeviceProfile) -> DirectPlayProfile? {
        profile.directPlayProfiles?.first
    }

    /// The profile serializes each list as a sorted CSV, so membership questions are set questions.
    private func csvParts(_ value: String?) -> Set<String> {
        Set((value ?? "").split(separator: ",").map(String.init))
    }

    // MARK: — DirectPlay

    /// DirectPlay is exactly the probed support: anything extra would be advertised as
    /// direct-playable when AVFoundation can't actually decode it.
    @Test("DirectPlay advertises exactly the probed AVPlayer support", arguments: [
        (withoutAV1, "mov,mp4", "h264,hevc", "aac,ac3,eac3"),
        (withAV1, "mov,mp4", "av1,h264,hevc", "aac,ac3,eac3,flac,opus"),
    ])
    func directPlayAdvertisesProbedSupport(support: AVPlayerSupport, containers: String, video: String, audio: String) throws {
        let profile = DeviceProfileTranslator.deviceProfile(from: caps(avPlayer: support))
        let entry = try #require(directPlayEntry(in: profile))
        #expect(entry.type == .video)
        #expect(entry.container == containers)
        #expect(entry.videoCodec == video)
        #expect(entry.audioCodec == audio)
    }

    @Test("The profile carries exactly one DirectPlay entry")
    func directPlayCount() {
        #expect((DeviceProfileTranslator.deviceProfile(from: caps()).directPlayProfiles ?? []).count == 1)
    }

    // MARK: — .hls exclusion (delivery format, not a source container)

    /// `hls` is a DELIVERY format, so advertising it as a direct-playable source container would
    /// invite the server to hand back a playlist where a file was expected. It must be stripped
    /// even though the capability set contains it.
    @Test("hls is stripped from the DirectPlay entry")
    func directPlayExcludesHLS() throws {
        let capabilities = caps()
        #expect(capabilities.avPlayer.containers.contains(.hls), "the input must actually contain hls")
        let entry = try #require(directPlayEntry(in: DeviceProfileTranslator.deviceProfile(from: capabilities)))
        #expect(csvParts(entry.container).contains(Container.hls.rawValue) == false)
    }

    // MARK: — TranscodingProfile

    @Test("TranscodingProfile targets HLS fMP4 (HEVC needs fMP4; TS black-screens HEVC); subtitles are NOT in the manifest (client renders sidecar VTT)")
    func transcoding() {
        let profile = DeviceProfileTranslator.deviceProfile(from: caps())
        let trans = profile.transcodingProfiles ?? []
        #expect(trans.count == 1)
        #expect(trans.first?.protocol == .hls)
        // fMP4, not TS: AVPlayer only decodes HEVC in fMP4 (Apple HLS spec), so a TS
        // transcode black-screens HEVC content (Swiftfin#1805).
        #expect(trans.first?.container == "mp4")
        #expect(trans.first?.type == .video)
        // Always request up to 7.1 (8ch); the OS downmixes/spatializes per route.
        // Without this Jellyfin defaults the transcode to 5.1 and downmixes 7.1 sources.
        #expect(trans.first?.maxAudioChannels == "8")
        // Keep subtitles out of the manifest: the client renders each sidecar VTT
        // itself, so the look is ours (one cross-engine overlay, future user-
        // customizable size/position/color) instead of AVKit's OS-overridable native pass.
        #expect(trans.first?.enableSubtitlesInManifest == false)
        // MinSegments=2 serves the playlist as soon as AVPlayer has enough to start.
        #expect(trans.first?.minSegments == 2)
    }

    /// Apple's HLS list filtered by the probe, order kept: the first entry is the server's
    /// encode target, and Opus is never offered because HLS does not allow it.
    @Test("TranscodingProfile codecs are Apple's HLS set filtered by the probed support", arguments: [
        (withoutAV1, "h264,hevc", "aac,ac3,eac3"),
        (withAV1, "h264,hevc,av1", "aac,ac3,eac3,flac"),
    ])
    func transcodingCodecs(support: AVPlayerSupport, video: String, audio: String) {
        let trans = DeviceProfileTranslator.deviceProfile(from: caps(avPlayer: support)).transcodingProfiles
        #expect(trans?.first?.videoCodec == video)
        #expect(trans?.first?.audioCodec == audio)
    }

    // MARK: — SubtitleProfiles

    /// Delivery method per format is the whole subtitle policy: TEXT formats are fetched and
    /// rendered client-side (one cross-engine overlay, and it dodges the in-manifest WebVTT drift),
    /// while IMAGE formats have no sidecar to render and must be burned in server-side.
    @Test(
        "Each text subtitle format declares the only delivery method that can work for it",
        arguments: ["vtt", "srt", "ass"]
    )
    func textSubtitleProfileMethods(format: String) {
        let subs = DeviceProfileTranslator.deviceProfile(from: caps()).subtitleProfiles ?? []
        #expect(subs.contains { $0.format == format && $0.method == .external })
    }

    /// The server matches a subtitle profile by string equality against the stream's own codec, so
    /// the burn-in declarations are only real if they name the identifiers a server actually
    /// reports. Pinning the emitted set to the shared Core list — rather than to a re-typed literal
    /// — is what keeps the profile and `MediaStreamInfo.isImageSubtitle` from drifting: a codec
    /// added to one is added to both, and a codec in neither can't be picked as burn-in anyway.
    @Test("Image subtitle formats declare burn-in, one profile per shared codec identifier")
    func imageSubtitleProfilesMatchSharedCodecList() {
        let subs = DeviceProfileTranslator.deviceProfile(from: caps()).subtitleProfiles ?? []
        let encoded = subs.filter { $0.method == .encode }.compactMap(\.format)
        #expect(Set(encoded) == Set(MediaStreamInfo.imageSubtitleCodecs))
        #expect(encoded.count == MediaStreamInfo.imageSubtitleCodecs.count, "no duplicate declarations")
        // The old short spellings matched nothing server-side; they must not come back.
        #expect(!encoded.contains("pgs"))
    }

    /// No subtitle may ride in the HLS manifest: an in-manifest WebVTT mis-times on fMP4 segments
    /// AND AVPlayer auto-renders it underneath our own sidecar (jellyfin#16647).
    @Test("No subtitle profile uses in-manifest HLS delivery")
    func noInManifestSubtitles() {
        let subs = DeviceProfileTranslator.deviceProfile(from: caps()).subtitleProfiles ?? []
        #expect(subs.contains { $0.method == .hls } == false)
    }

    // MARK: — CodecProfiles (unchanged)

    @Test("CodecProfile gates H.264 to 8-bit 4:2:0 profiles (excludes High 10)")
    func h264ProfileGuard() {
        let profile = DeviceProfileTranslator.deviceProfile(from: caps())
        let codecs = profile.codecProfiles ?? []
        let h264 = codecs.first { $0.codec == "h264" && $0.type == .video }
        let condition = h264?.conditions?.first { $0.property == .videoProfile }
        #expect(condition?.condition == .equalsAny)
        #expect(condition?.value == "high|main|baseline|constrained baseline")
    }

    @Test("CodecProfile constrains HEVC bit depth to ≤ 10")
    func hevcBitDepthGuard() {
        let profile = DeviceProfileTranslator.deviceProfile(from: caps())
        let codecs = profile.codecProfiles ?? []
        let hevc = codecs.first { $0.codec == "hevc" && $0.type == .video }
        let condition = hevc?.conditions?.first { $0.property == .videoBitDepth }
        #expect(condition?.condition == .lessThanEqual)
        #expect(condition?.value == "10")
    }

    @Test("HEVC range gate is static: HDR bases + DV-with-fallback always pass (AVPlayer tone-maps on SDR displays), bare DOVI/DOVIWithEL never")
    func hevcRangeGateStatic() {
        // caps() declares hdr: .none — the whitelist must NOT shrink for
        // it: gating HDR10 on the probe forced an SDR-mode Apple TV into a 4K
        // server tone-map it couldn't sustain (endless buffering, -12889).
        let profile = DeviceProfileTranslator.deviceProfile(from: caps())
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

    @Test("HEVC CodecProfile gates on VideoProfile main/main10 — VideoToolbox can't decode RExt/SCC")
    func hevcVideoProfileGuard() {
        let profile = DeviceProfileTranslator.deviceProfile(from: caps())
        let hevc = (profile.codecProfiles ?? []).first { $0.codec == "hevc" && $0.type == .video }
        let condition = hevc?.conditions?.first { $0.property == .videoProfile }
        #expect(condition?.condition == .equalsAny)
        #expect(condition?.isRequired == false)
        // Not Jellyfin's own "main 10" spelling: a match narrows hevc-profile to main10, the server
        // labels its SDR re-encode variant hvc1.2, and the iPad picks it over the HDR copy.
        #expect(condition?.value == "main|main10")
    }

    /// The probe answers at codec-family level; the Main-profile gate is what keeps AV1
    /// High/Professional streams off a decoder that rejects them.
    @Test("An AV1 CodecProfile gates Main profile, ≤ 10-bit and the HDR10/HLG ranges, only when AVPlayer plays AV1")
    func av1ProfileGuard() throws {
        let without = DeviceProfileTranslator.deviceProfile(from: caps(avPlayer: Self.withoutAV1))
        #expect((without.codecProfiles ?? []).contains { $0.codec == "av1" } == false)

        let with = DeviceProfileTranslator.deviceProfile(from: caps(avPlayer: Self.withAV1))
        let av1 = try #require((with.codecProfiles ?? []).first { $0.codec == "av1" && $0.type == .video })
        #expect(av1.conditions == [
            ProfileCondition(condition: .equalsAny, isRequired: false, property: .videoProfile, value: "main"),
            ProfileCondition(condition: .lessThanEqual, isRequired: false, property: .videoBitDepth, value: "10"),
            ProfileCondition(
                condition: .equalsAny, isRequired: false, property: .videoRangeType, value: "SDR|HDR10|HDR10Plus|HLG"
            ),
            ProfileCondition(condition: .lessThanEqual, isRequired: false, property: .width, value: "3840"),
            ProfileCondition(condition: .lessThanEqual, isRequired: false, property: .height, value: "2160"),
        ])
    }

    @Test("Every video CodecProfile caps Width/Height at capabilities.maxResolution")
    func resolutionCeilingConditions() {
        let custom = Resolution(width: 1920, height: 1080)
        let profile = DeviceProfileTranslator.deviceProfile(
            from: dolbyVisionCaps(avPlayer: Self.withAV1, maxResolution: custom)
        )
        let codecs = profile.codecProfiles ?? []
        for codec in ["h264", "hevc", "av1"] {
            let entry = codecs.first { $0.codec == codec && $0.type == .video }
            let width = entry?.conditions?.first { $0.property == .width }
            let height = entry?.conditions?.first { $0.property == .height }
            #expect(width?.condition == .lessThanEqual, "\(codec) missing Width condition")
            #expect(width?.value == String(custom.width), "\(codec) Width should reflect maxResolution")
            #expect(height?.condition == .lessThanEqual, "\(codec) missing Height condition")
            #expect(height?.value == String(custom.height), "\(codec) Height should reflect maxResolution")
        }
    }

    @Test("HEVC videoRangeType includes DOVI when capabilities.hdr contains .dolbyVision")
    func hevcRangeIncludesDOVIWhenDolbyVisionSupported() {
        let profile = DeviceProfileTranslator.deviceProfile(from: dolbyVisionCaps())
        let hevc = (profile.codecProfiles ?? []).first { $0.codec == "hevc" && $0.type == .video }
        let condition = hevc?.conditions?.first { $0.property == .videoRangeType }
        let entries = Set((condition?.value ?? "").split(separator: "|").map(String.init))
        #expect(entries.contains("DOVI"), "bare DOVI must be declared once hardware DV decode is confirmed")
        // The base-layer variants stay too — DOVI is additive, not a replacement.
        #expect(entries.contains("DOVIWithHDR10"))
    }

    // MARK: — Bitrate caps

    @Test("Bitrate caps are serialized from capabilities.maxBitrate")
    func serializesBitrateCap() {
        let capabilities = caps()
        let profile = DeviceProfileTranslator.deviceProfile(from: capabilities)
        // nil here would make Jellyfin apply its 8 Mbps default and re-encode 4K HDR to 1080p SDR.
        let expected = Int(capabilities.maxBitrate.rawValue)
        #expect(profile.maxStreamingBitrate == expected)
        #expect(profile.maxStaticBitrate == expected)
    }
}
