import SwiftUI
import ParallaxCore

/// Hosts the real root content with the launch stage played over it on cold
/// launch. `content` keeps ONE structural identity for the whole process
/// lifetime — the stage is a conditional `.overlay` and the settle zoom is a
/// plain animated modifier value, never an `if/else` branch or a
/// `TimelineView` wrapper around the content. Branching the content would
/// remount the entire tab tree when the stage tears down, cancelling and
/// re-running every `.task` (a visible Home refetch right as the iris
/// finishes — the original bug here).
struct LaunchRevealHost<Content: View>: View {
    @Environment(LaunchGate.self) private var gate
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ViewBuilder let content: Content

    /// The handoff's `homeScale` settle (1.09 → 1.0), driven by a SwiftUI
    /// animation that the overlay kicks off at the settle keyframe — not by
    /// per-frame writes, which would need the content inside a TimelineView.
    @State private var settleScale = LaunchStageMetrics.homeSettleScale

    private var stageActive: Bool { !gate.isFinished && !reduceMotion }

    var body: some View {
        content
            // Identity scale the moment the stage is gone (or never ran):
            // Reduce Motion must not render even one frame at 1.09, and a
            // story that completed while backgrounded must not replay the
            // settle zoom over the already-revealed UI.
            .scaleEffect(stageActive ? settleScale : 1.0)
            .overlay {
                if stageActive {
                    LaunchStageOverlay(gate: gate) {
                        // ≈ the spec's cubic ease-out for the homeScale settle.
                        withAnimation(.timingCurve(0.33, 1, 0.68, 1, duration: LaunchClock.settleRealDuration)) {
                            settleScale = 1.0
                        }
                    }
                }
            }
            // The status-bar / system-overlay hide rides the stage OVERLAY (below), not
            // here: emitting `.statusBarHidden(false)` on this base branch the rest of the
            // session left a permanent EXPLICIT false competing with the player's
            // `.statusBarHidden(true)` (a sibling `.overlay` at the root) — and on iPad,
            // where the status bar exists in every orientation, the launch host's false won,
            // so the player chrome could hide while the status bar stubbornly stayed. (The
            // home indicator hid fine because `.persistentSystemOverlays(.automatic)` is a
            // "no preference, defer" value, not a competing one.) Scoping the hide to the
            // overlay — mounted only while `stageActive` — means nothing emits a status-bar
            // preference once the stage is gone, so the player's preference stands alone.
            // A `rearm()` (logged-out launch → first Home after sign-in) brings the
            // stage back. Reset the settle zoom to its 1.09 start so the replay lifts
            // into place again instead of resting at the identity it settled to.
            .onChange(of: stageActive) { _, active in
                if active { settleScale = LaunchStageMetrics.homeSettleScale }
            }
            .onChange(of: gate.isFinished) { _, finished in
                // A rearm() under Reduce Motion brings the gate back to not-finished, but
                // `stageActive` stays false (reduceMotion dominates) so no overlay ever mounts to
                // finish it again — re-settle at once to keep the terminal "finished" invariant.
                if !finished, reduceMotion { gate.finish() }
            }
            .onAppear {
                // Spec: Reduce Motion skips the story entirely.
                if reduceMotion { gate.finish() }
            }
    }
}

/// The active story: the full-screen stage canvas, driven by one
/// display-link clock. Sits over the (settling) content and blocks input
/// until the gate finishes.
private struct LaunchStageOverlay: View {
    let gate: LaunchGate
    /// Fired when the story reaches the settle keyframe (skipped when the
    /// story is already complete — nothing left to settle into).
    let onSettleStart: () -> Void

    /// Failsafe: the hold is designed to loop until `markContentReady()`,
    /// but a release path that never fires (hung bootstrap, a future router
    /// destination nobody wired up) must not leave an input-blocking overlay
    /// up forever. Generous on purpose — real loads release long before this.
    private static let watchdogTimeout: Duration = .seconds(15)

    var body: some View {
        TimelineView(.animation) { timeline in
            let elapsed = timeline.date.timeIntervalSince(gate.startDate)
            let position = LaunchClock.position(
                elapsed: elapsed, releasedAtRawTime: gate.releasedAtRawTime
            )
            let complete = LaunchClock.isComplete(
                elapsed: elapsed, releasedAtRawTime: gate.releasedAtRawTime
            )
            LaunchStageView(storyTime: position.storyTime, holdPhase: position.holdPhase)
                // `initial: true` on both: a crossing that happened while the
                // scene wasn't rendering (backgrounded mid-launch) must still
                // fire on the first frame back.
                .onChange(of: position.storyTime >= LaunchClock.settleStart, initial: true) { _, crossed in
                    if crossed && !complete { onSettleStart() }
                }
                .onChange(of: complete, initial: true) { _, done in
                    if done { gate.finish() }
                }
        }
        .ignoresSafeArea()
        // The stage hides the status bar + system overlays while it's up — and ONLY while
        // it's up. Because this overlay is conditionally mounted (`if stageActive`), the
        // preference simply vanishes when the stage tears down rather than flipping to an
        // explicit `false`/`.automatic` that would fight the player's hide (see the note in
        // `LaunchRevealHost.body`).
        .persistentSystemOverlays(.hidden)
        #if !os(tvOS)
        .statusBarHidden(true)
        #endif
        .task {
            try? await Task.sleep(for: Self.watchdogTimeout)
            gate.markContentReady()
        }
    }
}
