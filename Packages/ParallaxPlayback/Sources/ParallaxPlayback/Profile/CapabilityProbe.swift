import Foundation
import ParallaxCore

/// Abstracts runtime device-capability queries that touch iOS-only APIs.
///
/// The concrete implementation (`LiveCapabilityProbe`) lives in the app target
/// and reads `AVPlayer.eligibleForHDRPlayback` plus VideoToolbox's Dolby Vision
/// decode check. This protocol keeps `ParallaxPlayback` free of UIKit and
/// device-bound AV APIs, so profile building stays deterministic under test via
/// injected fakes.
public protocol CapabilityProbe: Sendable {
    func hdrSupport() -> HDRSupport
}
