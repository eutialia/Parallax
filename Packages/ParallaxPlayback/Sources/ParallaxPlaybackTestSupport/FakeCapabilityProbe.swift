import Foundation
import ParallaxCore
import ParallaxPlayback

/// Deterministic test double for `CapabilityProbe`.
public struct FakeCapabilityProbe: CapabilityProbe {
    public let stubbedHDR: HDRSupport
    public let stubbedAudioOutput: AudioOutputCapability

    public init(
        hdr: HDRSupport = .none,
        audioOutput: AudioOutputCapability = .stereo
    ) {
        self.stubbedHDR = hdr
        self.stubbedAudioOutput = audioOutput
    }

    @MainActor public func hdrSupport() -> HDRSupport { stubbedHDR }
    public func audioOutput() -> AudioOutputCapability { stubbedAudioOutput }
}
