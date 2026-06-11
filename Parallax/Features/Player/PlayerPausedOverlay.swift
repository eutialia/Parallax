import SwiftUI

/// tvOS paused-status layer: a dim wash plus a flat centered pause glyph, shown
/// while playback is paused and stable (no scrub, no stall scrim). The glyph sits
/// exactly where iPad's play/pause disc sits and at the same glyph size — but bare,
/// translucent, disc-less and glass-less ON PURPOSE: it reports state, and anything
/// platter-shaped on tvOS reads as focusable. Never intercepts input; the remote's
/// play/pause works straight through it.
struct PlayerPausedOverlay: View {
    let metrics: PlayerMetrics
    /// The floor brings the dim; `.fullHUD` already has the controls scrim, so the
    /// glyph rides alone there (stacked dims read as a brightness glitch).
    var dimmed: Bool = true

    var body: some View {
        ZStack {
            if dimmed {
                PlayerScrimStyle.dim(PlayerScrimStyle.pausedDim)
            }
            Image(systemName: "pause.fill")
                .font(.system(size: metrics.pausedGlyph, weight: .semibold))
                .foregroundStyle(.white.opacity(0.65))
                .shadow(color: .black.opacity(0.35), radius: 10 * metrics.u, y: 2 * metrics.u)
        }
        .allowsHitTesting(false)
    }
}

#Preview("Paused · floor (dimmed)") {
    ZStack {
        LinearGradient(colors: [.orange, .black], startPoint: .topLeading, endPoint: .bottomTrailing)
            .ignoresSafeArea()
        PlayerPausedOverlay(metrics: .tv)
    }
    .frame(width: 1280, height: 720)
    .environment(\.colorScheme, .dark)
}

#Preview("Paused · over HUD scrim (undimmed)") {
    ZStack {
        LinearGradient(colors: [.orange, .black], startPoint: .topLeading, endPoint: .bottomTrailing)
            .ignoresSafeArea()
        PlayerPausedOverlay(metrics: .tv, dimmed: false)
    }
    .frame(width: 1280, height: 720)
    .environment(\.colorScheme, .dark)
}
