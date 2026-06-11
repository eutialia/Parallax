#if os(tvOS)
import AVFoundation
import AVKit
import UIKit
import ParallaxPlayback

/// Drives the TV's Match Content display-mode switch (HDR / native frame rate)
/// for the custom player. `AVPlayerViewController` does this automatically; a
/// bare `AVPlayerLayer` host must load the asset's `preferredDisplayCriteria`
/// and set it on the key window's `AVDisplayManager` — Apple's documented
/// custom-player path. Without it the TV stays in the UI's SDR mode for HDR
/// content while other apps (system player, YouTube) switch correctly
/// (device-diagnosed 2026-06-11: "the HDR is gone on tvOS").
///
/// TIMING IS THE CONTRACT: `prepare` must run between `engine.load` and
/// `engine.play`, never after frames are rendering. A display-mode switch
/// blanks and re-handshakes HDMI (HDCP re-auth at HDR bandwidths) for seconds;
/// applying it mid-render wedged the video pipeline in device tests — black
/// video with live audio, crackling audio, or a frozen frame that decayed into
/// a permanent `waitingToPlay(minimizeStalls)` stall. AVKit sequences the same
/// way: criteria apply at item load, playback starts after the display settles.
///
/// The system only honors the hint when the user's Match Content settings
/// allow; `nil` hands mode selection back to the system, so `clear()` runs on
/// player exit — NOT on transient phase dips (a track-switch re-buffer must
/// not flap the TV's display mode).
@MainActor
enum DisplayCriteriaMatcher {
    /// Hint the loaded item's native display mode and wait (bounded) for the
    /// TV's mode switch to settle so the caller starts playback on a stable
    /// display. AVKit engines only — VLC renders through its own pipeline and
    /// exposes no AVAsset to derive criteria from. Re-run per stream load: a
    /// repeat apply with unchanged criteria triggers no switch and returns
    /// after the short arm window.
    static func prepare(for engine: any PlaybackEngine) async {
        guard let hosting = engine as? AVPlayerHosting,
              let asset = hosting.avPlayer.currentItem?.asset,
              let manager = keyDisplayManager(),
              manager.isDisplayCriteriaMatchingEnabled
        else { return }
        guard let criteria = try? await asset.load(.preferredDisplayCriteria) else { return }
        manager.preferredDisplayCriteria = criteria
        await settleModeSwitch(manager)
    }

    /// Back to the system's UI-appropriate mode (player dismissed).
    static func clear() {
        keyDisplayManager()?.preferredDisplayCriteria = nil
    }

    /// `isDisplayModeSwitchInProgress` arms asynchronously after the criteria
    /// land, so first wait a short window for a switch to start at all (none
    /// starts when the display already matches), then wait out the switch
    /// itself. Deadlines keep a TV that never reports completion from stalling
    /// playback forever; cancellation (player exit) bails immediately.
    private static func settleModeSwitch(_ manager: AVDisplayManager) async {
        let clock = ContinuousClock()
        let armDeadline = clock.now.advanced(by: .milliseconds(800))
        while !manager.isDisplayModeSwitchInProgress {
            guard clock.now < armDeadline else { return }
            do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
        }
        let switchDeadline = clock.now.advanced(by: .seconds(8))
        while manager.isDisplayModeSwitchInProgress, clock.now < switchDeadline {
            do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
        }
    }

    private static func keyDisplayManager() -> AVDisplayManager? {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        return (scene?.keyWindow ?? scene?.windows.first)?.avDisplayManager
    }
}
#endif
