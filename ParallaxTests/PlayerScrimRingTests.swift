import Foundation
import Testing
@testable import Parallax

/// Pins the indeterminate ring's continuity: the arc grows head-first, shrinks
/// tail-first (the chase), and BOTH ends must be continuous at the half-cycle
/// seam (grow→shrink) and the loop seam (cycle restart). Two prior failures
/// live here: the original port teleported the head −172° per cycle, and the
/// design-faithful "hold then snap" teleported the tail +172° into the head
/// ("the tail skips half of the circle" — device-rejected).
@Suite("PlayerScrimRing arc continuity")
struct PlayerScrimRingTests {
    private func tail(_ t: TimeInterval) -> Double {
        PlayerScrimRing.arcRotation(t).truncatingRemainder(dividingBy: 360)
    }

    /// Head angle in degrees at time t: tail rotation + arc length.
    private func head(_ t: TimeInterval) -> Double {
        (PlayerScrimRing.arcRotation(t) + PlayerScrimRing.arcSweep(t) * 360)
            .truncatingRemainder(dividingBy: 360)
    }

    /// Shortest angular distance, degrees.
    private func angularGap(_ a: Double, _ b: Double) -> Double {
        let d = abs(a - b).truncatingRemainder(dividingBy: 360)
        return min(d, 360 - d)
    }

    @Test("head and tail are both continuous at every half- and full-cycle seam")
    func bothEndsContinuousAtSeams() {
        let epsilon = 0.0005   // spin drift over 2ε is ~0.23° — well under the bound
        // Half-cycle seams (grow→shrink) and loop seams (cycle restart) alike.
        for halfCycle in 1...16 {
            let seam = PlayerScrimRing.dashPeriod * Double(halfCycle) / 2
            let headGap = angularGap(head(seam - epsilon), head(seam + epsilon))
            let tailGap = angularGap(tail(seam - epsilon), tail(seam + epsilon))
            #expect(headGap < 1, "head jumped \(headGap)° at seam \(halfCycle)/2")
            #expect(tailGap < 1, "tail jumped \(tailGap)° at seam \(halfCycle)/2")
        }
    }

    @Test("sweep breathes: max at the half-cycle, min at the loop, continuous at both")
    func sweepBreathes() {
        let period = PlayerScrimRing.dashPeriod
        #expect(PlayerScrimRing.arcSweep(period / 2) > 0.45)
        let epsilon = 0.0005
        // The loop seam no longer snaps — both sides sit at the seed sweep.
        #expect(PlayerScrimRing.arcSweep(period - epsilon) < 0.02)
        #expect(PlayerScrimRing.arcSweep(period + epsilon) < 0.02)
        #expect(abs(PlayerScrimRing.arcSweep(period - epsilon) - PlayerScrimRing.arcSweep(period + epsilon)) < 0.001)
    }
}
