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
    private static let rotationPeriod: TimeInterval = 1.55
    private static let dashPeriod: TimeInterval = 1.4
    // Dash keyframes normalized by the design's 92pt ring circumference (≈271.7),
    // so the arc covers the same angular fractions at any rendered size.
    private static let minSweep = 2.0 / 271.7
    private static let maxSweep = 132.0 / 271.7
    private static let midLead = 22.0 / 271.7
    private static let endLead = 152.0 / 271.7

    var body: some View {
        TimelineView(.animation(paused: reduceMotion)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            // Reduce Motion: the same composition at rest — a static quarter arc.
            let sweep = reduceMotion ? 0.25 : arcSweep(t)
            let rotation = reduceMotion ? -90 : arcRotation(t)
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
    /// the first half-cycle and holds through the second (per the CSS keyframes).
    private func arcSweep(_ t: TimeInterval) -> Double {
        let p = dashPhase(t)
        guard p < 0.5 else { return Self.maxSweep }
        return Self.minSweep + (Self.maxSweep - Self.minSweep) * easeInOut(p / 0.5)
    }

    /// Continuous spin plus the dash-offset's forward crawl (0→22→152 units), which
    /// makes the arc's tail chase its head instead of shrinking in place.
    private func arcRotation(_ t: TimeInterval) -> Double {
        let spin = t.truncatingRemainder(dividingBy: Self.rotationPeriod) / Self.rotationPeriod
        let p = dashPhase(t)
        let lead = p < 0.5
            ? Self.midLead * easeInOut(p / 0.5)
            : Self.midLead + (Self.endLead - Self.midLead) * easeInOut((p - 0.5) / 0.5)
        // Each dash cycle ends with the lead at `endLead` but restarts it at 0 — the
        // CSS loop snaps the arc ~201° there every 1.4s. Carrying the completed
        // cycles forward keeps the rotation continuous; within a cycle it's the
        // same motion, just phase-shifted by a constant.
        let completedCycles = (t / Self.dashPeriod).rounded(.down)
        return (spin + lead + Self.endLead * completedCycles)
            .truncatingRemainder(dividingBy: 1) * 360
    }

    private func dashPhase(_ t: TimeInterval) -> Double {
        t.truncatingRemainder(dividingBy: Self.dashPeriod) / Self.dashPeriod
    }

    /// Smoothstep ≈ CSS ease-in-out.
    private func easeInOut(_ x: Double) -> Double { x * x * (3 - 2 * x) }
}

#Preview("Ring sizes") {
    ZStack {
        Color.black.ignoresSafeArea()
        HStack(spacing: 48) {
            PlayerScrimRing(size: 92, stroke: 5.5)   // buffering
            PlayerScrimRing(size: 80, stroke: 5)     // audio switch
            PlayerScrimRing(size: 64, stroke: 3.9)   // phone scale
        }
    }
}
