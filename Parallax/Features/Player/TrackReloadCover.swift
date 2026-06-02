import SwiftUI

/// Frosted-glass cover shown while the player reloads — e.g. switching the audio
/// track re-transcodes the stream, which forces a brief re-buffer. It frosts over
/// the paused/frozen frame (the engine is reused, so the last frame stays on screen)
/// and runs a slow shimmer sweep, so the wait reads as active "flow" rather than a
/// frozen screen. Replaces the plain loading spinner.
///
/// App target only: pure SwiftUI, no platform conditionals.
struct TrackReloadCover: View {
    /// Seconds per shimmer sweep across the width.
    private let period: TimeInterval = 1.8

    var body: some View {
        Rectangle()
            .fill(.ultraThinMaterial)
            .overlay(shimmer)
            .ignoresSafeArea()
            .allowsHitTesting(false)
    }

    /// A soft highlight band that glides across the frosted glass on a loop. Driven
    /// by `TimelineView(.animation)` so the motion is continuous and frame-rate
    /// independent (no view-identity animation to restart on re-render).
    private var shimmer: some View {
        TimelineView(.animation) { context in
            GeometryReader { geo in
                let width = geo.size.width
                let band = width * 0.45
                let elapsed = context.date.timeIntervalSinceReferenceDate
                let phase = elapsed.truncatingRemainder(dividingBy: period) / period
                LinearGradient(
                    colors: [.clear, .white.opacity(0.22), .clear],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(width: band)
                // Sweep from just off the leading edge to just off the trailing edge.
                .offset(x: -band + (width + band) * phase)
                .blendMode(.plusLighter)
            }
        }
    }
}

#Preview {
    ZStack {
        LinearGradient(colors: [.indigo, .black], startPoint: .top, endPoint: .bottom)
            .ignoresSafeArea()
        TrackReloadCover()
    }
}
