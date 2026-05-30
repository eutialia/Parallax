import Testing
import Foundation
@testable import ParallaxCore

@Suite("DeviceCapabilities two-tier extension")
struct DeviceCapabilitiesTwoTierTests {

    private func makeCaps(
        softwareVideo: [VideoCodec] = [],
        softwareAudio: [AudioCodec] = [],
        softwareContainers: [Container] = []
    ) -> DeviceCapabilities {
        DeviceCapabilities(
            supportedVideoCodecs: [.h264, .hevc],
            supportedAudioCodecs: [.aac, .ac3, .eac3, .mp3],
            supportedContainers: [.mp4, .mov, .hls],
            hdr: .none,
            maxResolution: .uhd4K,
            maxBitrate: .megabits(120),
            audioOutput: .stereo,
            preferredSubtitleFormats: [.vtt, .srt],
            softwareVideoCodecs: softwareVideo,
            softwareAudioCodecs: softwareAudio,
            softwareContainers: softwareContainers
        )
    }

    @Test("softwareVideoCodecs round-trips through init")
    func softwareVideoCodecsRoundTrips() {
        let caps = makeCaps(softwareVideo: [.vp9, .av1])
        #expect(Set(caps.softwareVideoCodecs) == [.vp9, .av1])
    }

    @Test("softwareAudioCodecs round-trips through init")
    func softwareAudioCodecsRoundTrips() {
        let caps = makeCaps(softwareAudio: [.dts, .trueHD, .flac, .opus])
        #expect(Set(caps.softwareAudioCodecs) == [.dts, .trueHD, .flac, .opus])
    }

    @Test("softwareContainers round-trips through init")
    func softwareContainersRoundTrips() {
        let caps = makeCaps(softwareContainers: [.mkv, .webm, .ts])
        #expect(Set(caps.softwareContainers) == [.mkv, .webm, .ts])
    }

    @Test("empty software fields are valid (hardware-only device)")
    func emptySoftwareFieldsAreValid() {
        let caps = makeCaps()
        #expect(caps.softwareVideoCodecs.isEmpty)
        #expect(caps.softwareAudioCodecs.isEmpty)
        #expect(caps.softwareContainers.isEmpty)
    }

    @Test(".stub has non-empty software fields")
    func stubHasNonEmptySoftwareFields() {
        let s = DeviceCapabilities.stub
        #expect(!s.softwareVideoCodecs.isEmpty)
        #expect(!s.softwareAudioCodecs.isEmpty)
        #expect(!s.softwareContainers.isEmpty)
    }

    @Test(".stub softwareVideoCodecs excludes h264 and hevc")
    func stubSoftwareVideoExcludesAVKit() {
        let s = DeviceCapabilities.stub
        #expect(!s.softwareVideoCodecs.contains(.h264))
        #expect(!s.softwareVideoCodecs.contains(.hevc))
    }

    @Test("DeviceCapabilities is Codable — round-trips with software fields")
    func codableRoundTrip() throws {
        let caps = makeCaps(
            softwareVideo: [.vp9, .av1],
            softwareAudio: [.dts, .flac],
            softwareContainers: [.mkv]
        )
        let encoded = try JSONEncoder().encode(caps)
        let decoded = try JSONDecoder().decode(DeviceCapabilities.self, from: encoded)
        #expect(Set(decoded.softwareVideoCodecs) == Set(caps.softwareVideoCodecs))
        #expect(Set(decoded.softwareAudioCodecs) == Set(caps.softwareAudioCodecs))
        #expect(Set(decoded.softwareContainers) == Set(caps.softwareContainers))
    }

    @Test("DeviceCapabilities is Hashable — two equal instances hash the same")
    func hashable() {
        let a = makeCaps(softwareVideo: [.vp9], softwareAudio: [.dts], softwareContainers: [.mkv])
        let b = makeCaps(softwareVideo: [.vp9], softwareAudio: [.dts], softwareContainers: [.mkv])
        #expect(a == b)
        #expect(a.hashValue == b.hashValue)
    }
}
