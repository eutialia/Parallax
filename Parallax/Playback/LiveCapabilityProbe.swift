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
        // `eligibleForHDRPlayback` already means "this device can present content
        // to an HDR display" — it accounts for the connected display and updates
        // on display changes. The old extra requirement that the UI screen report
        // a P3 gamut broke Apple TV: a tvOS session commonly runs its UI in SDR
        // (match-content setups), the probe then claimed no HDR, the new
        // videoRangeType gate excluded HDR10, and the server was forced into a
        // 4K tone-map re-encode it couldn't sustain in realtime — endless
        // buffering with -12889 segment timeouts (device-diagnosed 2026-06-10).
        // Per TN3145, AVPlayer tone-maps HDR optimally on any Apple device, so
        // delivering HDR10 whenever the device is eligible is safe. Dolby Vision
        // is still deliberately NOT claimed.
        AVPlayer.eligibleForHDRPlayback ? .hdr10 : .none
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
