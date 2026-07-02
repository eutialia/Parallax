import SwiftUI

/// The player's one loading primitive: a Material/YouTube-style white indeterminate
/// ring — a faint full-circle track under a bright arc that grows and shrinks while
/// the whole ring spins. Replaces the liquid-glass orb. The native circular
/// `ProgressView` is deliberately not used: it renders the spoked activity-indicator
/// style, not the clean ring the design specifies.
///
/// App target only: pure SwiftUI, no platform conditionals.
struct PlayerScrimRing: View {
    /// Outer diameter.
    var size: CGFloat
    /// Stroke width of both the track and the arc.
    var stroke: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // Design timings (scrims.css): the ring rotates 360° in 1.55s linear while the
    // arc's dash grows 2→132 units and its offset crawls 0→-152 over 1.4s
    // ease-in-out, both endless.
    private nonisolated static let rotationPeriod: TimeInterval = 1.55
    nonisolated static let dashPeriod: TimeInterval = 1.4
    // Arc bounds normalized by the design's 92pt ring circumference (≈271.7),
    // so the arc covers the same angular fractions at any rendered size.
    //
    // DELIBERATE deviation from the design CSS: its keyframes GROW the dash then
    // HOLD it through the second half-cycle, snapping back at the loop — which
    // forces one end of the arc to teleport ~172° every 1.4s (device-rejected:
    // "the tail skips half of the circle to where the head is"). Instead the
    // second half SHRINKS the arc — the tail chases the head along the circle —
    // which closes the loop with both ends continuous, by construction.
    private nonisolated static let minSweep = 2.0 / 271.7
    private nonisolated static let maxSweep = 132.0 / 271.7

    var body: some View {
        TimelineView(.animation(paused: reduceMotion)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            // Reduce Motion: the same composition at rest — a static quarter arc.
            let sweep = reduceMotion ? 0.25 : Self.arcSweep(t)
            let rotation = reduceMotion ? -90 : Self.arcRotation(t)
            ZStack {
                ring.stroke(.white.opacity(0.16), lineWidth: stroke)
                ring.trim(from: 0, to: sweep)
                    .stroke(.white, style: StrokeStyle(lineWidth: stroke, lineCap: .round))
                    .rotationEffect(.degrees(rotation))
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)   // the owning scrim labels the whole state
    }

    /// Inset so the centred stroke stays inside the frame.
    private var ring: some InsettableShape { Circle().inset(by: stroke / 2) }

    /// Fraction of the circle the bright arc covers: grows 2→132 dash units across
    /// the first half-cycle (head runs ahead), shrinks back across the second
    /// (tail catches up). Continuous everywhere — no hold-and-snap.
    /// Static + internal: pure math, unit-tested for cycle-boundary continuity.
    nonisolated static func arcSweep(_ t: TimeInterval) -> Double {
        let p = dashPhase(t)
        return p < 0.5
            ? minSweep + (maxSweep - minSweep) * easeInOut(p / 0.5)
            : maxSweep - (maxSweep - minSweep) * easeInOut((p - 0.5) / 0.5)
    }

    /// Rotation of the arc's TAIL (`trim` draws from here, head = tail + sweep):
    /// continuous spin, plus the tail's chase across the second half-cycle —
    /// while the arc shrinks, the tail travels forward to meet the head.
    ///
    /// Continuity proof sketch (per cycle, relative to the spin): first half the
    /// tail rests and the head advances by `maxSweep − minSweep` (the growth);
    /// second half the head rests and the tail advances by the same amount (the
    /// chase). Carrying `maxSweep − minSweep` per completed cycle makes BOTH
    /// ends land exactly where the next cycle picks them up — verified at the
    /// half-cycle seam and the loop seam in `PlayerScrimRingTests`.
    nonisolated static func arcRotation(_ t: TimeInterval) -> Double {
        let spin = t.truncatingRemainder(dividingBy: rotationPeriod) / rotationPeriod
        let p = dashPhase(t)
        let chase = p < 0.5 ? 0 : (maxSweep - minSweep) * easeInOut((p - 0.5) / 0.5)
        let completedCycles = (t / dashPeriod).rounded(.down)
        return (spin + chase + (maxSweep - minSweep) * completedCycles)
            .truncatingRemainder(dividingBy: 1) * 360
    }

    private nonisolated static func dashPhase(_ t: TimeInterval) -> Double {
        t.truncatingRemainder(dividingBy: dashPeriod) / dashPeriod
    }

    /// Smoothstep ≈ CSS ease-in-out.
    private nonisolated static func easeInOut(_ x: Double) -> Double { x * x * (3 - 2 * x) }
}

// The shipped sizes, derived from the live metrics so this can't go stale: the
// ring traces the centre play/pause disc (`scrimRing == transportPlay` — see
// PlayerMetrics), one geometry per device class.
#Preview("Ring sizes") {
    ZStack {
        Color.black.ignoresSafeArea()
        HStack(spacing: 48) {
            PlayerScrimRing(size: PlayerMetrics.tv.scrimRing,
                            stroke: PlayerMetrics.tv.scrimRingStroke)      // tvOS (u = 1)
            PlayerScrimRing(size: PlayerMetrics(width: 1366).scrimRing,
                            stroke: PlayerMetrics(width: 1366).scrimRingStroke)  // iPad
            PlayerScrimRing(size: PlayerMetrics.phone.scrimRing,
                            stroke: PlayerMetrics.phone.scrimRingStroke)   // iPhone
        }
    }
}
