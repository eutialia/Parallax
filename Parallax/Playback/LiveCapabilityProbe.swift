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
        let wideGamut = activeDisplayGamut == .P3
        return (eligible && wideGamut) ? .hdr10 : .none
    }

    /// Display gamut of the active scene's screen. Replaces the deprecated
    /// `UIScreen.main` (iOS 26): UIKit wants the screen read contextually from the
    /// window scene that manages the app's windows, not the global main screen.
    /// Falls back to `.unspecified` (→ no wide-gamut, conservative non-HDR) when no
    /// foreground scene is attached.
    @MainActor
    private var activeDisplayGamut: UIDisplayGamut {
        let scene = UIApplication.shared.connectedScenes
            .first { $0.activationState == .foregroundActive } as? UIWindowScene
        return scene?.screen.traitCollection.displayGamut ?? .unspecified
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
