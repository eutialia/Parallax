import Foundation
import ParallaxCore
@testable import ParallaxPlayback

/// Deterministic test double for `CapabilityProbe`.
/// Construct with the HDR + audio-output you want to probe and inject into
/// `DeviceProfileBuilder`. No platform API is touched.
struct FakeCapabilityProbe: CapabilityProbe {
    let stubbedHDR: HDRSupport
    let stubbedAudioOutput: AudioOutputCapability

    init(
        hdr: HDRSupport = .none,
        audioOutput: AudioOutputCapability = .stereo
    ) {
        self.stubbedHDR = hdr
        self.stubbedAudioOutput = audioOutput
    }

    @MainActor func hdrSupport() -> HDRSupport {
        stubbedHDR
    }

    func audioOutput() -> AudioOutputCapability {
        stubbedAudioOutput
    }
}
