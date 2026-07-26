import Foundation
import Testing
@testable import ParallaxCore

@Suite("DeviceCapabilities")
struct DeviceCapabilitiesTests {
    @Test("a composed HDR capability answers for each flavour it contains")
    func hdrIsDerivedNotEchoed() {
        let caps = DeviceCapabilities(
            supportedVideoCodecs: [.h264, .hevc],
            supportedAudioCodecs: [.aac, .eac3],
            supportedContainers: [.mp4, .hls],
            hdr: .both,
            maxResolution: .uhd4K,
            maxBitrate: .megabits(80),
            audioOutput: .multichannel(channelCount: 6),
            preferredSubtitleFormats: [.vtt, .srt]
        )

        #expect(caps.hdr.includes(.dolbyVision))
        #expect(caps.hdr.includes(.hdr10))
    }

    @Test("two values built from the same fields compare equal")
    func equality() {
        #expect(DeviceCapabilities.stub == DeviceCapabilities.stub)
    }

    /// The one Codable round trip for this type — `.stub` populates both tiers, so encoding it
    /// covers every field a two-tier-only round trip would.
    @Test("round-trips through Codable with both tiers intact")
    func codableRoundTrip() throws {
        try assertCodableRoundTrip(DeviceCapabilities.stub)
    }
}

@Suite("DeviceCapabilities two-tier extension")
struct DeviceCapabilitiesTwoTierTests {
    /// Hardware-only device: the AVKit tier is populated, the software tier defaults to empty.
    private static let hardwareOnly = DeviceCapabilities(
        supportedVideoCodecs: [.h264, .hevc],
        supportedAudioCodecs: [.aac, .ac3, .eac3, .mp3],
        supportedContainers: [.mp4, .mov, .hls],
        hdr: .none,
        maxResolution: .uhd4K,
        maxBitrate: .megabits(120),
        audioOutput: .stereo,
        preferredSubtitleFormats: [.vtt, .srt]
    )

    @Test("the software tier defaults to empty — a hardware-only device is expressible")
    func softwareTierDefaultsEmpty() {
        let caps = Self.hardwareOnly
        #expect(caps.softwareVideoCodecs.isEmpty)
        #expect(caps.softwareAudioCodecs.isEmpty)
        #expect(caps.softwareContainers.isEmpty)
    }

    @Test(".stub carries a populated software tier so tier-routing suites have both sides")
    func stubHasNonEmptySoftwareFields() {
        let stub = DeviceCapabilities.stub
        #expect(stub.softwareVideoCodecs.isEmpty == false)
        #expect(stub.softwareAudioCodecs.isEmpty == false)
        #expect(stub.softwareContainers.isEmpty == false)
    }

    /// The two tiers must stay disjoint on video: a codec AVKit decodes in hardware has no
    /// business in the software list, or the engine selector would route it to VLC needlessly.
    @Test("the two tiers are disjoint: no AVKit-native video codec appears in the software tier",
          arguments: DeviceCapabilities.stub.supportedVideoCodecs)
    func stubSoftwareVideoExcludesAVKit(codec: VideoCodec) {
        #expect(DeviceCapabilities.stub.softwareVideoCodecs.contains(codec) == false)
    }
}
