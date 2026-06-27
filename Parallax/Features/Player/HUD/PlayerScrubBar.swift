import SwiftUI
import CoreMedia

/// The lone progress bar shown while seeking with the chrome down — `PlayerProgressBar`
/// in `.scrub` mode (big floating time bubble + chapter ticks) pinned to the scrubber's
/// resting spot. Shared by EVERY seek-with-no-HUD path so they read as the same bar:
/// - tvOS swipe-scrub / click-seek (the reducer's `.swipeScrub` / `.clickSeek`).
/// - iOS/iPadOS double-tap ±10s, riding the `PlayerSeekFlash` dome (faded with it).
///
/// It shares the full-HUD scrubber's geometry (inset, track, labels, row height) so the
/// floor↔HUD switch reads as one persistent bar, not a jump-cut. Visual only
/// (`allowsHitTesting(false)`): the owner drives `progress`; seeking is the remote (tvOS)
/// or the double-tap (touch).
struct PlayerScrubBar: View {
    /// The discrete-step glide shared by tvOS click-seek and the touch double-tap burst:
    /// the head springs to its new ±step target while the bubble digits roll with it.
    static let scrubSpring: Animation = .snappy(duration: 0.25, extraBounce: 0)

    let metrics: PlayerMetrics
    let vm: PlayerViewModel
    /// Scrub-head fraction (0...1): the tvOS analog swipe head, the click-seek target, or
    /// the touch double-tap burst's accumulated target.
    let progress: Double
    /// Head/label POSITION animation. Nil pins the head 1:1 to `progress` — tvOS analog
    /// swipe, where the displayed position must equal the value a Select commits; a spring
    /// glides discrete ±steps (click-seek, double-tap). The bubble's digit roll always runs
    /// on `scrubSpring`, so even a 1:1 head keeps its "aliveness".
    var positionAnimation: Animation? = scrubSpring

    var body: some View {
        // The timestamp keeps rolling on its OWN transaction (scrubDigitRoll) even when
        // the head is pinned 1:1 below — the digit roll is the position-free half of the
        // "aliveness" the old single spring bundled with the (accuracy-killing) glide.
        PlayerProgressBar(scrubbingTo: progress, vm: vm, metrics: metrics,
                          mode: .scrub, showsBubble: true, scrubDigitRoll: Self.scrubSpring)
            // Position: a discrete ±step glides to its target; analog swipe tracks the head
            // 1:1 so the displayed position == the value Select commits. A follow spring
            // desyncs them — worst on the 23.976/24Hz panel Match-Frame-Rate pins for 24p
            // film, where its settle spans ~6 frames (felt as "trails my finger"). Keyed on
            // the CLAMPED value (the displayed head) so an out-of-range delta that doesn't
            // move the head can't fire a spurious transaction.
            .animation(positionAnimation, value: min(max(progress, 0), 1))
            // Pinned to the EXACT spot the full-HUD scrubber rests at (shared
            // `scrubberInsetX`/`scrubberBottom`) so a seek bar and the HUD bar never sit at
            // different heights/widths. Caller mounts this in a safe-area-respecting context
            // (same as the HUD scrubber), so equal pads resolve to the same screen point.
            .padding(.horizontal, metrics.scrubberInsetX)
            .padding(.bottom, metrics.scrubberBottom)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .environment(\.colorScheme, .dark)
            .allowsHitTesting(false)
    }
}

extension PlayerProgressBar {
    /// Configures a scrub bar from a 0...1 `fraction` + the view model — the ONE place the
    /// "fraction → time labels + bubble" derivation lives, so every scrub surface reads
    /// identically. Shared by `PlayerScrubBar` (the read-only seek bar / tvOS seek) and the
    /// interactive HUD scrubber. The *driver* (finger drag vs double-tap vs remote) and the
    /// *packaging* (placement, gestures, focus) stay with each caller; only this readout
    /// derivation is shared. Lives in an extension so `PlayerProgressBar`'s value-only
    /// memberwise init — what the previews and tests use — is preserved.
    init(scrubbingTo fraction: Double, vm: PlayerViewModel, metrics: PlayerMetrics,
         mode: Mode, showsBubble: Bool,
         scrubDigitRoll: Animation? = nil,
         onScrubChanged: ((Double) -> Void)? = nil,
         onScrubEnded: ((Double) -> Void)? = nil) {
        let dur = CMTimeGetSeconds(vm.currentDuration)
        let p = min(max(fraction, 0), 1)
        let shown = p * dur
        let remaining = max(0, dur - shown)
        self.init(
            metrics: metrics, mode: mode, played: p, buffered: vm.bufferedFraction,
            elapsed: formatPlaybackTime(shown),
            remaining: remaining > 0 ? "-\(formatPlaybackTime(remaining))" : formatPlaybackTime(dur),
            elapsedSeconds: shown, remainingSeconds: remaining,
            chapters: vm.chapterFractions,
            bubbleTime: showsBubble ? formatPlaybackTime(shown) : nil,
            bubbleChapter: showsBubble ? vm.chapterTitle(atSeconds: shown) : nil,
            onScrubChanged: onScrubChanged, onScrubEnded: onScrubEnded,
            scrubDigitRoll: scrubDigitRoll
        )
    }
}
