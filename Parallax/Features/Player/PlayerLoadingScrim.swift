import SwiftUI

/// The player's "calm" loading scrim — a dim wash over the live video surface with
/// the white indeterminate ring and a shimmering caption. Replaces the liquid-glass
/// orb. Two flavors, named for what's BEHIND the scrim: `.coldStart` (first load
/// over the black floor — nothing to watch yet, heavy dim) and `.liveFrame` (a
/// frame is on screen and is still the subject — a track-switch reload or a
/// mid-stream stall; light dim). Purely visual: the caller turns hit testing off
/// so the HUD mounted below stays interactive while the stream resolves.
///
/// App target only: pure SwiftUI, no platform conditionals.
struct PlayerLoadingScrim: View {
    enum Mode {
        case coldStart
        case liveFrame
    }

    var mode: Mode
    /// Nil shows the ring alone, no caption (the design's `label={null}` mode).
    var label: String?
    var sublabel: String? = nil
    var metrics: PlayerMetrics

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Drives the one-shot rise+fade entrance.
    @State private var entered = false

    var body: some View {
        ZStack {
            PlayerScrimStyle.dim(
                mode == .coldStart ? PlayerScrimStyle.coldStartDim : PlayerScrimStyle.liveFrameDim
            )
            content
                .opacity(entered ? 1 : 0)
                .offset(y: entered ? 0 : PlayerScrimStyle.riseOffset)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            withAnimation(reduceMotion ? nil : PlayerScrimStyle.rise) { entered = true }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityCaption)
        .accessibilityAddTraits(.updatesFrequently)
    }

    private var accessibilityCaption: String {
        let label = label ?? "Loading"
        return sublabel.map { "\(label), \($0)" } ?? label
    }

    private var content: some View {
        // One geometry for every mode: the ring never changes size, and the
        // sublabel line is RESERVED even when absent (hidden placeholder), so
        // the circle's center holds across Loading ↔ Buffering ↔ Switching
        // cross-fades instead of jumping scale and height per flavor.
        VStack(spacing: metrics.scrimCaptionGap) {
            PlayerScrimRing(size: metrics.scrimRing, stroke: metrics.scrimRingStroke)
            if let label {
                VStack(spacing: metrics.scrimCaptionLineGap) {
                    ShimmerLabel(text: label, size: metrics.scrimLabelSize)
                    Text(sublabel ?? " ")
                        .font(.system(size: metrics.scrimSubSize, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.62))
                        .opacity(sublabel == nil ? 0 : 1)
                }
                .multilineTextAlignment(.center)
            }
        }
    }
}

/// White label with a darker band swept across the glyphs (the design's shimmer:
/// white → 45% white → white, 2.4s linear loop). Static white under Reduce Motion.
private struct ShimmerLabel: View {
    var text: String
    var size: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let sweepPeriod: TimeInterval = 2.4

    var body: some View {
        let base = Text(text)
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(.white)
        if reduceMotion {
            base
        } else {
            base.overlay {
                TimelineView(.animation) { context in
                    let phase = (context.date.timeIntervalSinceReferenceDate / Self.sweepPeriod)
                        .truncatingRemainder(dividingBy: 1)
                    GeometryReader { geo in
                        let w = geo.size.width
                        // A soft dark band, masked to the glyphs, marching left→right:
                        // the text dims to ~45% as the band passes.
                        LinearGradient(
                            colors: [.clear, .black.opacity(0.55), .clear],
                            startPoint: .leading, endPoint: .trailing
                        )
                        .frame(width: w * 0.6)
                        .offset(x: -w * 0.8 + (w * 1.6) * phase)
                    }
                }
                .mask(base)
                .allowsHitTesting(false)
            }
        }
    }
}

#Preview("Buffering") {
    ZStack {
        LinearGradient(colors: [PlayerScrimStyle.previewBackdrop, .black],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
            .ignoresSafeArea()
        PlayerLoadingScrim(mode: .coldStart, label: "Loading",
                           metrics: PlayerMetrics(width: 1280))
    }
    .frame(width: 1280, height: 720)
}

#Preview("Audio switch") {
    ZStack {
        LinearGradient(colors: [PlayerScrimStyle.previewBackdrop, .black],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
            .ignoresSafeArea()
        PlayerLoadingScrim(mode: .liveFrame, label: "Switching audio",
                           sublabel: "English · 5.1 · AC3",
                           metrics: PlayerMetrics(width: 1280))
    }
    .frame(width: 1280, height: 720)
}

// Both flavors overlaid at half opacity: the rings must coincide EXACTLY (one
// geometry, reserved sublabel line) — any double ring or vertical ghosting
// means a mode is moving the circle again.
#Preview("Mode parity (overlay)") {
    ZStack {
        Color.black.ignoresSafeArea()
        PlayerLoadingScrim(mode: .coldStart, label: "Buffering",
                           metrics: PlayerMetrics(width: 1280))
            .opacity(0.5)
        PlayerLoadingScrim(mode: .liveFrame, label: "Switching audio",
                           sublabel: "English · 5.1 · AC3",
                           metrics: PlayerMetrics(width: 1280))
            .opacity(0.5)
    }
    .frame(width: 1280, height: 720)
}
