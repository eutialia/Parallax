import SwiftUI

/// Double-tap seek affordance (the design's YouTube vocabulary): a radial dome
/// darkens the tapped side while three chevrons march in the seek direction over
/// an accumulating "N seconds" label, and a ripple blooms from the tap point.
/// No full-surface dim — the gesture is the affordance, so the picture stays the
/// subject. Purely visual (hit testing off): the owner mounts one per burst and
/// bumps `trigger` on every repeat tap. Repeat taps EXTEND the flash, they don't
/// restart it — the dome holds and the chevrons keep looping (the prototype's
/// infinite march) while only the ripple re-blooms per tap; the fade-out runs
/// `PlayerSeekFlash.duration` after the last tap, when the owner clears the state.
///
/// App target only: pure SwiftUI, no platform conditionals (the double-tap gesture
/// driving it is wired by the touch platforms; tvOS seeks through its HUD reducer).
struct PlayerSeekFlash: View {
    enum Direction { case backward, forward }

    var direction: Direction
    /// Accumulated skip for the running burst: 10, 20, 30…
    var seconds: Int
    /// Tap location in the player surface's coordinate space — the ripple's origin.
    var tapPoint: CGPoint
    /// Bumped by the owner on every tap of the burst — re-arms the ripple and
    /// pushes the fade-out back; the march loop is never reset.
    var trigger: Int
    var metrics: PlayerMetrics
    /// Diagnostic/preview hook: freezes the flash at a fixed progress (0…1) of a
    /// single-tap timeline. Never set in production.
    var frozenProgress: Double? = nil

    /// One march cycle — and the time after the LAST tap at which the owner
    /// clears the flash (the fade-out tail runs inside it).
    static let duration: TimeInterval = 0.9

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// First tap of the burst — anchors the rise and the looping march.
    @State private var burstStart = Date.now
    /// Latest tap — anchors the ripple bloom and the fade-out.
    @State private var lastTap = Date.now

    var body: some View {
        GeometryReader { geo in
            TimelineView(.animation(paused: reduceMotion || frozenProgress != nil)) { context in
                flash(at: context.date, in: geo.size)
            }
        }
        .allowsHitTesting(false)
        .onChange(of: trigger) { lastTap = .now }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(direction == .forward ? "Skipped forward" : "Skipped back") \(seconds) seconds")
    }

    /// Seconds since the burst began — the rise + march clock.
    private func sinceBurstStart(at date: Date) -> TimeInterval {
        if let frozenProgress { return frozenProgress * Self.duration }
        // Reduce Motion: a single held frame at the flash's peak (no march/ripple);
        // the owner's timed clear still dismisses it.
        if reduceMotion { return 0.3 * Self.duration }
        return max(date.timeIntervalSince(burstStart), 0)
    }

    /// Seconds since the latest tap — the ripple + fade-out clock.
    private func sinceLastTap(at date: Date) -> TimeInterval {
        if let frozenProgress { return frozenProgress * Self.duration }
        if reduceMotion { return 0.3 * Self.duration }
        return max(date.timeIntervalSince(lastTap), 0)
    }

    private func flash(at date: Date, in size: CGSize) -> some View {
        let sinceStart = sinceBurstStart(at: date)
        let sinceLast = sinceLastTap(at: date)
        let forward = direction == .forward
        let domeWidth = size.width * 0.46
        let domeHeight = size.height * 1.16   // bleeds ±8% past the surface
        let domeCenterX = forward ? size.width - domeWidth / 2 : domeWidth / 2
        let fade = envelope(sinceStart: sinceStart, sinceLast: sinceLast)

        return ZStack {
            dome(forward: forward, width: domeWidth, height: domeHeight)
                .position(x: domeCenterX, y: size.height / 2)
                .opacity(fade)

            if !reduceMotion {
                // 27u base = the prototype's rendered 18px at its 1280-wide harness
                // (u ≈ 0.667), so the bloom covers the same fraction of any surface.
                let ripple = min(sinceLast / Self.duration, 1)
                Circle()
                    .fill(.white.opacity(0.5))
                    .frame(width: 27 * metrics.u, height: 27 * metrics.u)
                    .scaleEffect(max(rippleScale(ripple), 0.001))
                    .opacity(rippleOpacity(ripple))
                    .position(tapPoint)
            }

            seekContent(sinceStart: sinceStart, forward: forward)
                .position(x: domeCenterX, y: size.height / 2)
                .opacity(fade)
        }
        .frame(width: size.width, height: size.height)
    }

    /// The side dome: an elliptical darkening centred toward the outer edge
    /// (design: `radial-gradient(120% 72% at 78%/22% 50%)`). The gradient layer is
    /// sized to the ellipse's full extent (2 × 1.2w, 2 × 0.72h) and positioned so
    /// its centre sits at the design's origin; it fades to clear just past the
    /// dome's inner edge, which is what forms the dome shape — no clip needed.
    private func dome(forward: Bool, width: CGFloat, height: CGFloat) -> some View {
        let base = Color(red: 6 / 255, green: 6 / 255, blue: 12 / 255)
        return EllipticalGradient(
            stops: [
                .init(color: base.opacity(0.52), location: 0),
                .init(color: base.opacity(0.24), location: 0.44),
                .init(color: .clear, location: 0.66),
            ],
            center: .center,
            startRadiusFraction: 0,
            endRadiusFraction: 0.5
        )
        .frame(width: width * 2.4, height: height * 1.44)
        .position(x: forward ? width * 0.78 : width * 0.22, y: height / 2)
        .frame(width: width, height: height)
    }

    private func seekContent(sinceStart: TimeInterval, forward: Bool) -> some View {
        VStack(spacing: metrics.seekContentGap) {
            HStack(spacing: 2 * metrics.u) {
                ForEach(0..<3, id: \.self) { slot in
                    // March order leads in the seek direction: left→right forward,
                    // right→left backward.
                    let order = forward ? slot : 2 - slot
                    let pulse = reduceMotion ? 1.0 : chevronPulse(sinceStart: sinceStart, order: order)
                    Image(systemName: forward ? "chevron.right" : "chevron.left")
                        .font(.system(size: metrics.seekChevronSize, weight: .semibold))
                        .foregroundStyle(.white)
                        .opacity(0.2 + 0.8 * pulse)
                        .scaleEffect(0.86 + 0.14 * pulse)
                        .shadow(color: .black.opacity(0.6), radius: 4.5, y: 1)
                }
            }
            Text("\(seconds) seconds")
                .font(.system(size: metrics.seekLabelSize, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.6), radius: 6, y: 2)
        }
    }

    /// Dome + content visibility: rise once at the burst's start, hold while taps
    /// keep landing, fall in the tail after the LAST tap — so a repeat tap extends
    /// the flash instead of blinking it back to frame zero.
    private func envelope(sinceStart: TimeInterval, sinceLast: TimeInterval) -> Double {
        let rise = min(sinceStart / (0.15 * Self.duration), 1)
        let fallStart = 0.6 * Self.duration
        let fall = sinceLast < fallStart
            ? 1
            : max(0, 1 - (sinceLast - fallStart) / (0.4 * Self.duration))
        return min(rise, fall)
    }

    /// The staggered scale/brighten march (0.12s steps in the design), looping every
    /// `duration` for as long as the burst keeps the flash alive — the prototype's
    /// infinite `scr-chev` cycle, not a per-tap one-shot.
    private func chevronPulse(sinceStart: TimeInterval, order: Int) -> Double {
        let offset = sinceStart - 0.12 * Double(order)
        guard offset > 0 else { return 0 }
        let x = (offset / Self.duration).truncatingRemainder(dividingBy: 1)
        if x < 0.22 { return x / 0.22 }
        if x < 0.55 { return 1 - (x - 0.22) / 0.33 }
        return 0
    }

    /// The tap ripple blooms 0→26× its base with an ease-out, gone by 60%.
    private func rippleScale(_ p: Double) -> Double {
        let x = min(p / 0.6, 1)
        return 26 * (1 - (1 - x) * (1 - x))
    }

    private func rippleOpacity(_ p: Double) -> Double {
        0.45 * max(0, 1 - p / 0.6)
    }
}

#Preview("Seek forward / back") {
    // A mid-grey "video" bed — bright enough to judge the dome's darkening, which
    // vanishes on a near-black background.
    let bed = LinearGradient(colors: [Color(white: 0.45), Color(white: 0.25)],
                             startPoint: .topLeading, endPoint: .bottomTrailing)
    VStack(spacing: 1) {
        ZStack {
            bed
            PlayerSeekFlash(direction: .forward, seconds: 20,
                            tapPoint: CGPoint(x: 1280 * 0.84, y: 360 * 0.55),
                            trigger: 0, metrics: PlayerMetrics(width: 1280),
                            frozenProgress: 0.3)
        }
        .frame(width: 1280, height: 360)
        ZStack {
            bed
            PlayerSeekFlash(direction: .backward, seconds: 10,
                            tapPoint: CGPoint(x: 1280 * 0.16, y: 360 * 0.45),
                            trigger: 0, metrics: PlayerMetrics(width: 1280),
                            frozenProgress: 0.7)
        }
        .frame(width: 1280, height: 360)
    }
}
