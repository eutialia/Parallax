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

    /// The caption renders on big screens only (`scrimShowsCaption`): a landscape
    /// iPhone has no room for it between the center-pinned ring and the bottom
    /// scrubber (see the metric's doc). The root accessibility label still carries
    /// the caption text on every platform.
    private var shownLabel: String? {
        metrics.scrimShowsCaption ? label : nil
    }

    private var content: some View {
        // The RING is pinned DEAD-CENTER on the screen — where the centre play/pause
        // disc lives (see `PlayerControlsView.showsCenterTransport`) — so the loading
        // arc traces the disc's exact circumference and the two swap in place. To keep
        // the ring centered while the caption hangs BELOW it, the caption is BALANCED by
        // an equal, HIDDEN copy ABOVE the ring: the symmetric VStack [hidden · ring ·
        // caption] centers on the ring, so the caption's height can never float the ring
        // up off the disc (the old plain VStack centered ring+caption together, which
        // did). The balancer is the STATIC variant — same text, same fonts, so the same
        // height — because `.hidden()` only skips compositing: a shimmering copy would
        // keep its TimelineView ticking a second per-frame gradient+mask for nobody.
        // The reserved sublabel line keeps both copies the same height — also holding
        // the ring still across Loading ↔ Buffering ↔ Switching cross-fades.
        // No caption ⇒ the ring alone, still centered.
        VStack(spacing: metrics.scrimCaptionGap) {
            if let label = shownLabel {
                caption(label, animated: false).hidden()
            }
            PlayerScrimRing(size: metrics.scrimRing, stroke: metrics.scrimRingStroke)
            if let label = shownLabel {
                caption(label, animated: true)
            }
        }
    }

    /// The shimmer label + reserved sublabel line, centered — hung beneath the ring.
    /// `animated: false` renders the identical layout with a static label (the hidden
    /// balancer's variant — no second shimmer timeline).
    private func caption(_ label: String, animated: Bool) -> some View {
        VStack(spacing: metrics.scrimCaptionLineGap) {
            ShimmerLabel(text: label, size: metrics.scrimLabelSize, animated: animated)
            Text(sublabel ?? " ")
                .font(.system(size: metrics.scrimSubSize, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.62))
                .opacity(sublabel == nil ? 0 : 1)
        }
        .multilineTextAlignment(.center)
    }
}

/// White label with a darker band swept across the glyphs (the design's shimmer:
/// white → 45% white → white, 2.4s linear loop). Static white under Reduce Motion
/// or `animated: false` (the scrim's hidden height-balancer — a hidden TimelineView
/// still ticks, so the balancer must never mount one).
private struct ShimmerLabel: View {
    var text: String
    var size: CGFloat
    var animated: Bool = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let sweepPeriod: TimeInterval = 2.4

    var body: some View {
        let base = Text(text)
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(.white)
        if reduceMotion || !animated {
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

/// Diagnostic: the loading veil (ring + caption) composited over the centre play/pause
/// disc, in the real full-bleed layout. Proves BOTH the ask (the ring traces the disc's
/// exact circumference — same center, same diameter, `scrimRing == transportPlay`) AND
/// that the caption still renders below the now-centered ring. The disc rides beneath the
/// veil at reduced opacity so the rim stays readable through the dim.
private struct RingDiscParityPreview: View {
    /// Show the full veil (dim + caption) or just the bare ring over the disc.
    var fullVeil: Bool
    /// The layout family to exercise — pad by default; `.tv` proves the tvOS case.
    var m = PlayerMetrics(width: 1180)

    var body: some View {
        // The ZStack centers its children and the backdrop makes it full-bleed, so
        // the disc/ring land dead-center with no extra frames — the real layout.
        ZStack {
            if fullVeil {
                PlayerScrimStyle.previewBed
            } else {
                Color.black.ignoresSafeArea()
            }
            PlayerRoundButton(systemImage: "play.fill", size: m.transportPlay,
                              iconScale: 0.46, accessibilityLabel: "Play") {}
                .opacity(fullVeil ? 0.5 : 1)
            if fullVeil {
                PlayerLoadingScrim(mode: .liveFrame, label: "Loading video",
                                   sublabel: "English · 5.1 · AC3", metrics: m)
            } else {
                PlayerScrimRing(size: m.scrimRing, stroke: m.scrimRingStroke)
            }
        }
        .environment(\.colorScheme, .dark)
    }
}

// Phone veil at landscape-phone size: the ring ALONE, dead-center — no caption
// (`scrimShowsCaption` is false on phone; a caption below a center-pinned ring
// lands in the bottom scrubber band on every landscape iPhone). Any text in this
// render is a regression. FIRST in the file: RenderPreview resolves index 0 most
// reliably (see the renderpreview-gotchas memory).
#Preview("Phone — ring only, no caption") {
    ZStack {
        PlayerScrimStyle.previewBed
        PlayerLoadingScrim(mode: .liveFrame, label: "Loading video",
                           sublabel: "English · 5.1 · AC3", metrics: .phone)
    }
    .frame(width: 852, height: 393)
}

// The tvOS full HUD DOES render a centre play/pause disc
// (PlayerControlsView.showsCenterTransport == true on tvOS; bigControls(.tv) draws it
// at `transportPlay`). This shows whether the tvOS ring (`scrimRing` at `.tv`) matches
// that disc's rim — if the arc sits inside the glass edge, the ring is UNDERSIZED for
// tvOS and the swap jumps.
#Preview("tvOS — ring vs play disc") { RingDiscParityPreview(fullVeil: false, m: .tv) }
#Preview("Veil + caption over disc") { RingDiscParityPreview(fullVeil: true) }
#Preview("Ring ⊚ play disc parity") { RingDiscParityPreview(fullVeil: false) }

#Preview("Buffering") {
    ZStack {
        PlayerScrimStyle.previewBed
        PlayerLoadingScrim(mode: .coldStart, label: "Loading",
                           metrics: PlayerMetrics(width: 1280))
    }
    .frame(width: 1280, height: 720)
}

#Preview("Audio switch") {
    ZStack {
        PlayerScrimStyle.previewBed
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
