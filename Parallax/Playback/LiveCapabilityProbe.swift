import AVFoundation
import CoreMedia
import VideoToolbox
import UIKit
import ParallaxCore
import ParallaxPlayback

/// Live `CapabilityProbe`. Lives in the app target: `ParallaxPlayback` stays
/// free of UIKit and device-bound AV APIs so profile building is deterministic
/// under test, and the no-drift rule forbids `#if os` in `Packages/`.
/// Injected into `DeviceProfileBuilder`.
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
        // delivering HDR10 whenever the device is eligible is safe.
        guard AVPlayer.eligibleForHDRPlayback else { return .none }
        var support: HDRSupport = .hdr10

        // Dolby Vision (bare profile 5, no fallback layer — see
        // DeviceProfileTranslator.codecProfiles). The obvious API,
        // `AVPlayer.availableHDRModes` (`AVPlayerHDRMode.dolbyVision`), is
        // deprecated as of iOS/tvOS 26 in favor of `eligibleForHDRPlayback` —
        // confirmed via the installed iOS 26 SDK header (AVPlayer.h): "Use
        // eligibleForHDRPlayback instead". That replacement collapses to a
        // single generic "some HDR is presentable" bit and can't distinguish
        // Dolby Vision from HDR10/HLG, so it can't stand in for the old
        // DV-specific check. `VTIsHardwareDecodeSupported` for the Dolby
        // Vision HEVC codec type is NOT deprecated and IS cross-platform (iOS
        // 11+ / tvOS 11+ per the VideoToolbox header) — it answers "can this
        // silicon decode a DV bitstream at all," which combined with the
        // HDR-eligible-display gate above is the closest available proxy for
        // "safe to declare bare DOVI to the server." It can't tell a
        // DV-capable panel from a generic-HDR one, but there is no narrower
        // public signal post-deprecation, on either iOS or tvOS.
        if VTIsHardwareDecodeSupported(kCMVideoCodecType_DolbyVisionHEVC) {
            support.insert(.dolbyVision)
        }
        return support
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
