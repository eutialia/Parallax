import SwiftUI

/// tvOS paused-status layer: a dim wash plus a flat centered glyph. The glyph sits
/// exactly where iPad's play/pause disc sits and at the same glyph size — but bare,
/// translucent, disc-less and glass-less ON PURPOSE: it reports state, and anything
/// platter-shaped on tvOS reads as focusable. Never intercepts input; the remote's
/// play/pause works straight through it.
///
/// It owns its OWN appear/morph/close lifecycle off `isPaused`, so the parent mounts it
/// for the whole eligible window (floor playback, not scrubbing/stalling) rather than
/// toggling it on `!isPlaying`:
///   nothing → (pause) pause glyph scales in → held while paused →
///   (resume) glyph morphs to play, lingers → scrim closes.
/// A plain show/hide cut straight from "paused" to gone the instant playback resumed,
/// with no play-glyph beat.
struct PlayerPausedOverlay: View {
    let metrics: PlayerMetrics
    /// The floor brings the dim; `.fullHUD` already has the controls scrim, so the
    /// glyph rides alone there (stacked dims read as a brightness glitch).
    var dimmed: Bool = true
    /// Live pause intent (`!vm.isPlaying`). Drives the lifecycle below.
    let isPaused: Bool

    @State private var visible = false
    @State private var glyph = "pause.fill"
    @State private var closeTask: Task<Void, Never>?

    /// How long the play glyph lingers after a resume before the scrim closes — long
    /// enough to read the morph, short enough to feel like an acknowledgement.
    private let resumeHold: Duration = .milliseconds(450)

    var body: some View {
        ZStack {
            if visible {
                if dimmed {
                    PlayerScrimStyle.dim(PlayerScrimStyle.pausedDim)
                        .transition(.opacity)
                }
                Image(systemName: glyph)
                    .font(.system(size: metrics.pausedGlyph, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.65))
                    .shadow(color: .black.opacity(0.35), radius: 10 * metrics.u, y: 2 * metrics.u)
                    // pause.fill ⇄ play.fill morph the bars into the triangle in place.
                    .contentTransition(.symbolEffect(.replace))
                    .animation(.snappy(duration: 0.32), value: glyph)
                    // Scale-in on appear / scale-out on close, distinct from the morph.
                    .transition(.scale(scale: 0.82).combined(with: .opacity))
            }
        }
        .allowsHitTesting(false)
        .animation(.easeOut(duration: 0.28), value: visible)
        .onChange(of: isPaused, initial: true) { _, paused in
            closeTask?.cancel()
            if paused {
                // Show (or morph back from a play glyph mid-close) and hold.
                glyph = "pause.fill"
                visible = true
            } else if visible {
                // Resume: morph the held pause glyph into play, linger, then close.
                glyph = "play.fill"
                closeTask = Task {
                    try? await Task.sleep(for: resumeHold)
                    guard !Task.isCancelled else { return }
                    visible = false
                }
            }
            // !paused && !visible (normal playback / first mount): stay hidden.
        }
        .onDisappear { closeTask?.cancel() }
    }
}

#Preview("Paused · floor (dimmed)") {
    ZStack {
        LinearGradient(colors: [.orange, .black], startPoint: .topLeading, endPoint: .bottomTrailing)
            .ignoresSafeArea()
        PlayerPausedOverlay(metrics: .tv, isPaused: true)
    }
    .frame(width: 1280, height: 720)
    .environment(\.colorScheme, .dark)
}

#Preview("Paused · over HUD scrim (undimmed)") {
    ZStack {
        LinearGradient(colors: [.orange, .black], startPoint: .topLeading, endPoint: .bottomTrailing)
            .ignoresSafeArea()
        PlayerPausedOverlay(metrics: .tv, dimmed: false, isPaused: true)
    }
    .frame(width: 1280, height: 720)
    .environment(\.colorScheme, .dark)
}
