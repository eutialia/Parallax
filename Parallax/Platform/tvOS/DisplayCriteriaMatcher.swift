#if os(tvOS)
import AVFoundation
import AVKit
import UIKit
import ParallaxCore

/// Drives the TV's Match Content display-mode switch (HDR / native frame rate)
/// for the custom player. `AVPlayerViewController` does this automatically; a
/// bare `AVPlayerLayer` host must load the asset's `preferredDisplayCriteria`
/// and set it on the key window's `AVDisplayManager` — Apple's documented
/// custom-player path. Without it the TV stays in the UI's SDR mode for HDR
/// content while other apps (system player, YouTube) switch correctly
/// (device-diagnosed 2026-06-11: "the HDR is gone on tvOS").
///
/// TIMING IS THE CONTRACT: `AVKitEngine` runs `prepare` after it builds the
/// asset and before the item reaches the player. A display-mode switch blanks
/// and re-handshakes HDMI (HDCP re-auth at HDR bandwidths) for seconds. Applied
/// while AVPlayer chose its variant, it failed the item with
/// `AVErrorNoCompatibleAlternatesForExternalDisplay` (device-confirmed on an
/// Apple TV 4K switching frame rate, 2026-11-15); applied mid-render, it wedged
/// the video pipeline (black video with live audio, or a frozen frame).
///
/// The system only honors the hint when the user's Match Content settings
/// allow; `nil` hands mode selection back to the system, so `clear()` runs on
/// player exit — NOT on transient phase dips (a track-switch re-buffer must
/// not flap the TV's display mode).
@MainActor
enum DisplayCriteriaMatcher {
    /// Hint the asset's native display mode and wait (bounded) for the TV's
    /// mode switch to settle, so the item reaches the player on a stable display.
    static func prepare(for asset: AVAsset) async {
        guard let manager = keyDisplayManager() else { return }
        guard manager.isDisplayCriteriaMatchingEnabled else {
            log.notice("display: matching off")
            return
        }
        guard let criteria = try? await asset.load(.preferredDisplayCriteria) else {
            log.notice("display: no criteria")
            return
        }
        let clock = ContinuousClock()
        let applied = clock.now
        manager.preferredDisplayCriteria = criteria
        let switched = await settleModeSwitch(manager)
        log.notice("display: \(switched ? "switched" : "no switch") in \(Int((clock.now - applied) / .milliseconds(1))) ms")
    }

    private static let log = Log.retained(category: "Display")

    /// Back to the system's UI-appropriate mode (player dismissed).
    static func clear() {
        keyDisplayManager()?.preferredDisplayCriteria = nil
    }

    /// `isDisplayModeSwitchInProgress` arms asynchronously after the criteria
    /// land, so first wait a short window for a switch to start at all (none
    /// starts when the display already matches), then wait out the switch
    /// itself. Deadlines keep a TV that never reports completion from stalling
    /// playback forever; cancellation (player exit) bails immediately.
    /// Returns whether a switch started.
    private static func settleModeSwitch(_ manager: AVDisplayManager) async -> Bool {
        let clock = ContinuousClock()
        let armDeadline = clock.now.advanced(by: .milliseconds(800))
        while !manager.isDisplayModeSwitchInProgress {
            guard clock.now < armDeadline else { return false }
            do { try await Task.sleep(for: .milliseconds(50)) } catch { return false }
        }
        let switchDeadline = clock.now.advanced(by: .seconds(8))
        while manager.isDisplayModeSwitchInProgress, clock.now < switchDeadline {
            do { try await Task.sleep(for: .milliseconds(100)) } catch { return true }
        }
        return true
    }

    private static func keyDisplayManager() -> AVDisplayManager? {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        return (scene?.keyWindow ?? scene?.windows.first)?.avDisplayManager
    }
}
#endif
