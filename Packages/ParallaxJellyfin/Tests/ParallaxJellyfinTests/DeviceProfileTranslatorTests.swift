import Foundation
import Testing
import JellyfinAPI
import ParallaxCore
@testable import ParallaxJellyfin

@Suite("DeviceProfile translation")
struct DeviceProfileTranslatorTests {

    // MARK: — Fixtures

    /// AVKit-native only: no software codecs, so no VLC tier may be emitted.
    private func avKitOnlyCaps() -> DeviceCapabilities {
        JellyfinFixtures.caps(containers: [.mp4, .mov])
    }

    /// Both tiers present. `hdr: .none` on purpose — several tests below assert the HEVC range
    /// whitelist does NOT shrink when the probe reports no HDR.
    private func tieredCaps(
        hdr: HDRSupport = .none,
        maxResolution: Resolution = .uhd4K,
        containers: [Container] = [.mp4, .mov]
    ) -> DeviceCapabilities {
        JellyfinFixtures.caps(
            containers: containers,
            hdr: hdr,
            maxResolution: maxResolution,
            softwareVideoCodecs: [.vc1, .mpeg2video, .vp9, .av1],
            softwareAudioCodecs: [.dts, .trueHD, .flac, .opus],
            softwareContainers: [.mkv, .webm, .avi, .ts, .mp3, .flac]
        )
    }

    /// Dolby Vision hardware decode confirmed — the one signal that adds bare DOVI to the gate.
    private func dolbyVisionCaps(maxResolution: Resolution = .uhd4K) -> DeviceCapabilities {
        tieredCaps(hdr: [.hdr10, .dolbyVision], maxResolution: maxResolution)
    }

    /// Mirrors `DeviceProfileBuilder.build()`, whose `supportedContainers` INCLUDES `.hls` — the
    /// input shape that proves hls is stripped rather than never present.
    private func realBuildCaps() -> DeviceCapabilities {
        tieredCaps(containers: [.mp4, .mov, .hls])
    }

    // MARK: — Tier lookup
    //
    // The two DirectPlay entries are distinguished by container membership: the AVKit tier carries
    // mp4 and never mkv, the software tier is the mkv one. Naming that once keeps a dozen
    // assertions from re-typing the predicate (and silently matching the wrong entry).

    private func avKitEntry(in profile: DeviceProfile) -> DirectPlayProfile? {
        (profile.directPlayProfiles ?? []).first {
            let container = $0.container ?? ""
            return container.contains("mp4") && !container.contains("mkv")
        }
    }

    private func vlcEntry(in profile: DeviceProfile) -> DirectPlayProfile? {
        (profile.directPlayProfiles ?? []).first { ($0.container ?? "").contains("mkv") }
    }

    /// The profile serializes each list as a sorted CSV, so membership questions are set questions.
    private func csvParts(_ value: String?) -> Set<String> {
        Set((value ?? "").split(separator: ",").map(String.init))
    }

    // MARK: — AVKit DirectPlay tier

    /// The AVKit tier is an EXACT set per field: anything extra would be advertised as
    /// direct-playable when AVFoundation can't actually decode it.
    @Test(
        "The AVKit DirectPlay tier advertises exactly the hardware-native sets",
        arguments: [ProfileField.container, .videoCodec, .audioCodec]
    )
    func avKitDirectPlayTier(field: ProfileField) throws {
        let capabilities = tieredCaps()
        let entry = try #require(avKitEntry(in: DeviceProfileTranslator.deviceProfile(from: capabilities)))
        #expect(entry.type == .video)
        // Compared against the capabilities under test, not a re-typed codec list.
        switch field {
        case .container:
            #expect(csvParts(entry.container) == Set(capabilities.supportedContainers.map(\.rawValue)))
        case .videoCodec:
            #expect(csvParts(entry.videoCodec) == Set(capabilities.supportedVideoCodecs.map(\.rawValue)))
        case .audioCodec:
            #expect(csvParts(entry.audioCodec) == Set(capabilities.supportedAudioCodecs.map(\.rawValue)))
        }
    }

    enum ProfileField: Sendable { case container, videoCodec, audioCodec }

    // MARK: — VLC DirectPlay tier

    /// The software tier exists only when the device reports software codecs, and each of its
    /// fields is derived from the capabilities' software sets — audio additionally keeps the AVKit
    /// codecs, since a VLC-routed file can still carry AAC.
    @Test(
        "The VLC DirectPlay tier is derived from the software capability sets",
        arguments: [ProfileField.container, .videoCodec, .audioCodec]
    )
    func vlcDirectPlayTier(field: ProfileField) throws {
        let capabilities = tieredCaps()
        let entry = try #require(vlcEntry(in: DeviceProfileTranslator.deviceProfile(from: capabilities)))
        #expect(entry.type == .video)
        switch field {
        case .container:
            #expect(csvParts(entry.container).isSuperset(of: Set(capabilities.softwareContainers.map(\.rawValue))))
        case .videoCodec:
            #expect(csvParts(entry.videoCodec) == Set(capabilities.softwareVideoCodecs.map(\.rawValue)))
        case .audioCodec:
            let audio = csvParts(entry.audioCodec)
            #expect(audio.isSuperset(of: Set(capabilities.softwareAudioCodecs.map(\.rawValue))))
            #expect(audio.isSuperset(of: Set(capabilities.supportedAudioCodecs.map(\.rawValue))))
        }
    }

    /// The routing rule this tier exists to express: a premium MKV must remux to AVKit rather than
    /// route to the software engine, so the hardware video codecs must NOT appear here.
    @Test("VLC DirectPlay video codecs exclude the AVKit-native ones")
    func vlcDirectPlayExcludesAVKitVideoCodecs() throws {
        let capabilities = tieredCaps()
        let entry = try #require(vlcEntry(in: DeviceProfileTranslator.deviceProfile(from: capabilities)))
        let codecs = csvParts(entry.videoCodec)
        for hardware in capabilities.supportedVideoCodecs.map(\.rawValue) {
            #expect(codecs.contains(hardware) == false, "\(hardware) must remux to AVKit, not route to VLC")
        }
    }

    @Test("No VLC DirectPlay entry when softwareVideoCodecs is empty (avKit-only caps)")
    func noVLCTierWhenSoftwareEmpty() {
        let profile = DeviceProfileTranslator.deviceProfile(from: avKitOnlyCaps())
        #expect(vlcEntry(in: profile) == nil,
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

    /// `hls` is a DELIVERY format, so advertising it as a direct-playable source container would
    /// invite the server to hand back a playlist where a file was expected. It must be stripped
    /// from both tiers even though the capability set contains it.
    @Test("hls is stripped from both DirectPlay tiers", arguments: [Tier.avKit, .vlc])
    func directPlayExcludesHLS(tier: Tier) throws {
        let capabilities = realBuildCaps()
        #expect(capabilities.supportedContainers.contains(.hls), "the input must actually contain hls")
        let profile = DeviceProfileTranslator.deviceProfile(from: capabilities)
        let entry = try #require(tier == .avKit ? avKitEntry(in: profile) : vlcEntry(in: profile))
        #expect(csvParts(entry.container).contains(Container.hls.rawValue) == false)
    }

    enum Tier: Sendable { case avKit, vlc }

    // MARK: — TranscodingProfile

    @Test("TranscodingProfile targets HLS fMP4 (HEVC needs fMP4; TS black-screens HEVC); subtitles are NOT in the manifest (client renders sidecar VTT)")
    func transcoding() {
        let profile = DeviceProfileTranslator.deviceProfile(from: tieredCaps())
        let trans = profile.transcodingProfiles ?? []
        #expect(trans.count == 1)
        #expect(trans.first?.protocol == .hls)
        // fMP4, not TS: AVPlayer only decodes HEVC in fMP4 (Apple HLS spec), so a TS
        // transcode black-screens HEVC content (Swiftfin#1805). fMP4's cost is the
        // `-noaccurate_seek` subtitle drift (jellyfin#15845), handled above the container.
        #expect(trans.first?.container == "mp4")
        #expect(trans.first?.type == .video)
        // These CSVs are the wire spec the server parses — the translator holds them as literals
        // and exposes no named constant, so the expectation is the literal by necessity.
        #expect(trans.first?.videoCodec == "h264,hevc")
        #expect(trans.first?.audioCodec == "aac,ac3,eac3")
        // Always request up to 7.1 (8ch); the OS downmixes/spatializes per route.
        // Without this Jellyfin defaults the transcode to 5.1 and downmixes 7.1 sources.
        #expect(trans.first?.maxAudioChannels == "8")
        // Keep subtitles out of the manifest: the client renders each sidecar VTT
        // itself, so the look is ours (one cross-engine overlay, future user-
        // customizable size/position/color) instead of AVKit's OS-overridable native pass.
        #expect(trans.first?.enableSubtitlesInManifest == false)
        // Startup-latency knobs (Swiftfin-matched): on the remux path the
        // segmenter can't force keyframes, so without BreakOnNonKeyFrames the
        // playlist waits on the source's long-GOP keyframes; MinSegments=2
        // serves it as soon as AVPlayer has enough to start.
        #expect(trans.first?.isBreakOnNonKeyFrames == true)
        #expect(trans.first?.minSegments == 2)
    }

    // MARK: — SubtitleProfiles

    /// Delivery method per format is the whole subtitle policy: TEXT formats are fetched and
    /// rendered client-side (one cross-engine overlay, and it dodges the in-manifest WebVTT drift),
    /// while IMAGE formats have no sidecar to render and must be burned in server-side.
    @Test(
        "Each subtitle format declares the only delivery method that can work for it",
        arguments: [
            ("vtt", SubtitleDeliveryMethod.external),
            ("srt", .external),
            ("ass", .external),
            ("pgs", .encode),
            ("vobsub", .encode),
        ]
    )
    func subtitleProfileMethods(format: String, method: SubtitleDeliveryMethod) {
        let subs = DeviceProfileTranslator.deviceProfile(from: tieredCaps()).subtitleProfiles ?? []
        #expect(subs.contains { $0.format == format && $0.method == method })
    }

    /// No subtitle may ride in the HLS manifest: an in-manifest WebVTT mis-times on fMP4 segments
    /// AND AVPlayer auto-renders it underneath our own sidecar (jellyfin#16647).
    @Test("No subtitle profile uses in-manifest HLS delivery")
    func noInManifestSubtitles() {
        let subs = DeviceProfileTranslator.deviceProfile(from: tieredCaps()).subtitleProfiles ?? []
        #expect(subs.contains { $0.method == .hls } == false)
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

    @Test("HEVC CodecProfile gates on VideoProfile main/main10 — VideoToolbox can't decode RExt/SCC")
    func hevcVideoProfileGuard() {
        let profile = DeviceProfileTranslator.deviceProfile(from: tieredCaps())
        let hevc = (profile.codecProfiles ?? []).first { $0.codec == "hevc" && $0.type == .video }
        let condition = hevc?.conditions?.first { $0.property == .videoProfile }
        #expect(condition?.condition == .equalsAny)
        #expect(condition?.isRequired == false)
        #expect(condition?.value == "main|main10")
    }

    @Test("Both video CodecProfiles cap Width/Height at capabilities.maxResolution")
    func resolutionCeilingConditions() {
        let custom = Resolution(width: 1920, height: 1080)
        let profile = DeviceProfileTranslator.deviceProfile(from: dolbyVisionCaps(maxResolution: custom))
        let codecs = profile.codecProfiles ?? []
        for codec in ["h264", "hevc"] {
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

    @Test("HEVC videoRangeType excludes DOVI when capabilities.hdr lacks .dolbyVision")
    func hevcRangeExcludesDOVIWhenDolbyVisionUnsupported() {
        // tieredCaps() declares hdr: .none.
        let profile = DeviceProfileTranslator.deviceProfile(from: tieredCaps())
        let hevc = (profile.codecProfiles ?? []).first { $0.codec == "hevc" && $0.type == .video }
        let condition = hevc?.conditions?.first { $0.property == .videoRangeType }
        let entries = Set((condition?.value ?? "").split(separator: "|").map(String.init))
        #expect(!entries.contains("DOVI"), "bare DOVI must not be declared without a confirmed DV decode signal")
    }

    // MARK: — Bitrate caps

    @Test("Bitrate caps are serialized from capabilities.maxBitrate")
    func serializesBitrateCap() {
        let capabilities = tieredCaps()
        let profile = DeviceProfileTranslator.deviceProfile(from: capabilities)
        // nil here would make Jellyfin apply its 8 Mbps default and re-encode 4K HDR to 1080p SDR.
        let expected = Int(capabilities.maxBitrate.rawValue)
        #expect(profile.maxStreamingBitrate == expected)
        #expect(profile.maxStaticBitrate == expected)
    }
}
