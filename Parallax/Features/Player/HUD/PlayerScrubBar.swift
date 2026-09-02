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
/// (`allowsHitTesting(false)`): the head follows the model's flight, so the owner brings
/// only the mount and the animation; seeking is the remote (tvOS) or the double-tap (touch).
struct PlayerScrubBar: View {
    /// The discrete-step glide shared by tvOS click-seek and the touch double-tap burst:
    /// the head springs to its new ±step target while the bubble digits roll with it.
    static let scrubSpring: Animation = .snappy(duration: 0.25, extraBounce: 0)

    let metrics: PlayerMetrics
    let vm: PlayerViewModel
    /// Head/label POSITION animation. Nil pins the head 1:1 to the model's virtual position —
    /// tvOS analog swipe, where the displayed position must equal the value a commit lands on;
    /// a spring glides discrete ±steps (click-seek, double-tap). The bubble's digit roll always
    /// runs on `scrubSpring`, so even a 1:1 head keeps its "aliveness".
    var positionAnimation: Animation? = scrubSpring

    var body: some View {
        // The timestamp keeps rolling on its OWN transaction (scrubDigitRoll) even when
        // the head is pinned 1:1 below — the digit roll is the position-free half of the
        // "aliveness" the old single spring bundled with the (accuracy-killing) glide.
        // `reportsPullExclusion: false` is load-bearing: this bar is `allowsHitTesting(false)`
        // (nothing can start a drag on it) and rides `TimelineView(.animation)` subtrees, so
        // reporting the exclusion zone would re-declare the preference on every animation
        // tick — see `PullExclusionReporter`.
        PlayerProgressBar(vm: vm, metrics: metrics,
                          mode: .scrub, playhead: .line, showsBubble: true,
                          scrubDigitRoll: Self.scrubSpring,
                          reportsPullExclusion: false)
            // Position: a discrete ±step glides to its target; analog swipe tracks the head
            // 1:1 so the displayed position == the value Select commits. A follow spring
            // desyncs them — worst on the 23.976/24Hz panel Match-Frame-Rate pins for 24p
            // film, where its settle spans ~6 frames (felt as "trails my finger").
            .animation(positionAnimation, value: vm.virtualFraction)
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
    /// Configures a scrub bar from the view model alone — the ONE place the "flight → head +
    /// time labels + bubble" derivation lives, so every scrub surface reads identically.
    /// Shared by `PlayerScrubBar` (the read-only seek bar / tvOS seek) and the interactive HUD
    /// scrubber. The caller brings only PACKAGING (mode, playhead, bubble, scrub handlers);
    /// the driver (finger drag vs double-tap vs remote) declares its seek to the model and
    /// reads the result back here. Lives in an extension so `PlayerProgressBar`'s value-only
    /// memberwise init — what the previews and tests use — is preserved.
    /// Both indicators are the view model's to declare, not the caller's: a `.previewing`
    /// flight means a gesture owns the bar, so the VIRTUAL position (ghost + bubble + readout)
    /// is where the gesture is aiming and the CONCRETE one — the position the picture is held
    /// on, the scrub's entry pause froze it there — keeps the played fill honest. Every scrub
    /// surface reads the same flight, so the two bars can't drift apart on what "the video is
    /// actually at X" means, and the split can't outlive the gesture that opened it.
    init(vm: PlayerViewModel, metrics: PlayerMetrics,
         mode: Mode, playhead: Playhead = .dot, showsBubble: Bool,
         scrubDigitRoll: Animation? = nil,
         onScrubChanged: ((Double) -> Void)? = nil,
         onScrubEnded: ((Double) -> Void)? = nil,
         reportsPullExclusion: Bool = true) {
        // Incomplete media plays with an `.indefinite` duration that never resolves (`dur` is NaN).
        // Without a known runtime there's no scrubbable timeline: show the LIVE elapsed position
        // only (no fraction, no total/remaining, no bubble, no scrub handlers), and let the bar
        // render its indeterminate dim-track form. `vm.hasKnownDuration` is the one truth every
        // such check reads. (`formatPlaybackTime` already maps a NaN to "0:00" defensively.)
        let known = vm.hasKnownDuration
        let dur = CMTimeGetSeconds(vm.currentDuration)
        let previewing = vm.flight?.stage == .previewing
        let p = vm.virtualFraction
        let shown = known ? p * dur : CMTimeGetSeconds(vm.currentPosition)
        let remaining = max(0, dur - shown)
        self.init(
            metrics: metrics, mode: mode, playhead: playhead, indeterminate: !known,
            played: known ? p : 0,
            concrete: previewing && known ? vm.concreteFraction : nil,
            buffered: known ? vm.bufferedFraction : nil,
            // Every scrub surface gets the pulse from the one place the readout is derived.
            // The flight itself is the newest-wins gate: a gesture supersedes what it
            // interrupts, and a `.previewing` stage publishes no span at all.
            flight: known ? vm.seekSpan : nil,
            elapsed: formatPlaybackTime(shown),
            remaining: known ? (remaining > 0 ? "-\(formatPlaybackTime(remaining))" : formatPlaybackTime(dur)) : "",
            elapsedSeconds: shown, remainingSeconds: known ? remaining : 0,
            chapters: known ? vm.chapterFractions : [],
            bubbleTime: showsBubble && known ? formatPlaybackTime(shown) : nil,
            bubbleChapter: showsBubble && known ? vm.chapterTitle(atSeconds: shown) : nil,
            onScrubChanged: known ? onScrubChanged : nil,
            onScrubEnded: known ? onScrubEnded : nil,
            scrubDigitRoll: scrubDigitRoll,
            reportsPullExclusion: reportsPullExclusion
        )
    }
}
