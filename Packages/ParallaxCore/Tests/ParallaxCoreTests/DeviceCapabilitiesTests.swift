import Foundation
import Testing
@testable import ParallaxCore

@Suite("DeviceCapabilities")
struct DeviceCapabilitiesTests {
    @Test("DeviceCapabilities constructs with all fields and is Sendable + Hashable")
    func constructs() {
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

        #expect(caps.supportedVideoCodecs.contains(.hevc))
        #expect(caps.hdr.includes(.dolbyVision))
        #expect(caps.maxBitrate == .megabits(80))
    }

    @Test("DeviceCapabilities equals another with the same fields")
    func equality() {
        let a = DeviceCapabilities.stub
        let b = DeviceCapabilities.stub
        #expect(a == b)
    }

    @Test("DeviceCapabilities round-trips through Codable")
    func codableRoundTrip() throws {
        let original = DeviceCapabilities.stub
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(DeviceCapabilities.self, from: data)
        #expect(decoded == original)
    }
}
