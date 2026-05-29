import AVFoundation
import UIKit
import ParallaxCore
import ParallaxPlayback

/// iOS-only `CapabilityProbe`. Lives in the app target because `UIScreen` and
/// `AVAudioSession` aren't on the macOS swift-test host, and the no-drift rule
/// forbids `#if os` in `Packages/`. Injected into `DeviceProfileBuilder`.
struct LiveCapabilityProbe: CapabilityProbe {
    @MainActor
    func hdrSupport() -> HDRSupport {
        // Conservative: claim HDR10 only when the system reports the device is
        // eligible for HDR playback AND the screen is wide-gamut (P3). Dolby
        // Vision is deliberately NOT claimed in Phase 4.
        let eligible = AVPlayer.eligibleForHDRPlayback
        let wideGamut = UIScreen.main.traitCollection.displayGamut == .P3
        return (eligible && wideGamut) ? .hdr10 : .none
    }

    nonisolated func audioOutput() -> AudioOutputCapability {
        let route = AVAudioSession.sharedInstance().currentRoute
        let maxChannels = route.outputs.map { $0.channels?.count ?? 2 }.max() ?? 2
        if maxChannels > 2 {
            return .multichannel(channelCount: maxChannels)
        }
        return .stereo
    }
}
