import Foundation
import ParallaxCore

/// Abstracts runtime device-capability queries that touch iOS-only APIs.
///
/// The concrete implementation (`LiveCapabilityProbe`) lives in the app target
/// and reads `AVPlayer.eligibleForHDRPlayback`, `UIScreen.main.traitCollection`,
/// and `AVAudioSession.sharedInstance().currentRoute`. This protocol keeps
/// `ParallaxPlayback` free of UIKit and device-bound AV APIs, so profile
/// building stays deterministic under test via injected fakes.
///
/// `hdrSupport()` is `@MainActor` because `UIScreen.main` is main-actor-bound
/// in `LiveCapabilityProbe`. The protocol reflects that constraint so
/// `DeviceProfileBuilder` can `await` the hop without an unsafe cast.
public protocol CapabilityProbe: Sendable {
    @MainActor func hdrSupport() -> HDRSupport
    func audioOutput() -> AudioOutputCapability
}
