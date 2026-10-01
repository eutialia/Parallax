import Foundation
import ParallaxCore
import ParallaxPlayback

/// Deterministic test double for `CapabilityProbe`.
public struct FakeCapabilityProbe: CapabilityProbe {
    public let stubbedHDR: HDRSupport

    public init(hdr: HDRSupport = .none) {
        self.stubbedHDR = hdr
    }

    public func hdrSupport() -> HDRSupport { stubbedHDR }
}
