import Foundation
import ParallaxCore
import ParallaxPlayback

/// Deterministic test double for `CapabilityProbe`.
public struct FakeCapabilityProbe: CapabilityProbe {
    public let stubbedHDR: HDRSupport
    public let stubbedAVPlayer: AVPlayerSupport

    public init(hdr: HDRSupport = .none, avPlayer: AVPlayerSupport = .baseline) {
        self.stubbedHDR = hdr
        self.stubbedAVPlayer = avPlayer
    }

    public func hdrSupport() -> HDRSupport { stubbedHDR }
    public func avPlayerSupport() -> AVPlayerSupport { stubbedAVPlayer }
}

extension AVPlayerSupport {
    /// What every Apple device plays: the default for tests that are not about the probe.
    public static let baseline = AVPlayerSupport(
        containers: [.mp4, .mov, .hls],
        videoCodecs: [.h264, .hevc],
        audioCodecs: [.aac, .ac3, .eac3]
    )
}
