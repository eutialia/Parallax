import Testing
import Foundation
@testable import ParallaxCore

// Expected values below are computed from the handoff README's tables with
// independent formula literals — not by calling the implementation's easings —
// so a porting slip in either layer fails loudly.

@Suite("LaunchEase")
struct LaunchEaseTests {
    @Test("endpoints are exact for every curve")
    func endpoints() {
        for ease in [LaunchEase.inOut, .out, .in, .inExpo, .outBack] {
            #expect(abs(ease(0) - 0) < 1e-12)
            #expect(abs(ease(1) - 1) < 1e-12)
        }
    }

    @Test("midpoint values match the spec formulas")
    func midpoints() {
        #expect(abs(LaunchEase.inOut(0.25) - 0.0625) < 1e-12)        // 4u³
        #expect(abs(LaunchEase.inOut(0.75) - 0.9375) < 1e-12)        // 1−(−2u+2)³/2
        #expect(abs(LaunchEase.out(0.5) - 0.875) < 1e-12)            // 1−(1−u)³
        #expect(abs(LaunchEase.in(0.5) - 0.125) < 1e-12)             // u³
        #expect(abs(LaunchEase.inExpo(0.5) - 0.03125) < 1e-12)       // 2^(10u−10)
        // 1 + 2.9(u−1)³ + 1.9(u−1)² at u=0.5 → 1 − 0.3625 + 0.475
        #expect(abs(LaunchEase.outBack(0.5) - 1.1125) < 1e-12)
    }
}

@Suite("launchTrack")
struct LaunchTrackTests {
    let stops: [LaunchKeyStop] = [
        .init(t: 1, v: 10), .init(t: 2, v: 20, ease: .out), .init(t: 4, v: 0),
    ]

    @Test("clamps before the first and after the last stop")
    func clamping() {
        #expect(launchTrack(0, stops) == 10)
        #expect(launchTrack(5, stops) == 0)
    }

    @Test("hits stop values exactly")
    func stopValues() {
        #expect(launchTrack(1, stops) == 10)
        #expect(abs(launchTrack(2, stops) - 20) < 1e-12)
        #expect(abs(launchTrack(4, stops)) < 1e-12)
    }

    @Test("eases into each stop with that stop's curve")
    func segmentEasing() {
        // 1→2 uses .out: 10 + 10 × (1−0.5³) = 18.75
        #expect(abs(launchTrack(1.5, stops) - 18.75) < 1e-12)
        // 2→4 uses default .inOut: 20 − 20 × 0.5 = 10 at the midpoint
        #expect(abs(launchTrack(3, stops) - 10) < 1e-12)
    }
}

@Suite("LaunchFrame")
struct LaunchFrameTests {
    @Test("opens exactly on the icon: t = 0")
    func openingPose() {
        let f = LaunchFrame.evaluate(storyTime: 0)
        #expect(f.pairOffset == SIMD2(16, 0))
        #expect(f.wobble == 0.03)
        #expect(f.turns == 1.06)
        #expect(f.ringBlur == 7)
        #expect(abs(f.ringScale - 0.92) < 1e-12)
        #expect(f.colorMix == 0)
        #expect(f.chromaOpacity == 0)   // rings fade in from nothing
        #expect(f.mergedOpacity == 0)
        #expect(f.clipRadius == 0)
        #expect(f.homeOpacity == 0)
        #expect(f.twistDegrees == 0)
        #expect(f.flowPhase == 0)
    }

    @Test("parallax twist peak: t = 1.34")
    func twistPeak() {
        let f = LaunchFrame.evaluate(storyTime: 1.34)
        #expect(abs(f.pairOffset.x - 25) < 1e-12)   // ICON_SEP + 9
        #expect(abs(f.twistDegrees - 5) < 1e-12)
    }

    @Test("merge: color resolves before the lines register")
    func mergeOrder() {
        // At 1.9 the color is already mono and the roughness is gone…
        let atMergeStart = LaunchFrame.evaluate(storyTime: 1.9)
        #expect(abs(atMergeStart.colorMix) < 1e-12)
        #expect(abs(atMergeStart.wobble) < 1e-12)
        #expect(abs(atMergeStart.turns - 1.0) < 1e-12)
        // …and the merged ring only exists from 2.06.
        #expect(LaunchFrame.evaluate(storyTime: 1.92).mergedOpacity == 0)
        #expect(abs(LaunchFrame.evaluate(storyTime: 2.06).mergedOpacity - 1) < 1e-12)
        #expect(LaunchFrame.evaluate(storyTime: 2.06).pairOffset.x == 0)
    }

    @Test("focus-snap overshoot: t = 1.98")
    func focusSnap() {
        let f = LaunchFrame.evaluate(storyTime: 1.98)
        #expect(abs(f.ringScale - 1.05) < 1e-12)
        #expect(abs(f.flashOpacity - 0.55) < 1e-12)
        #expect(abs(f.flashScale - 0.9) < 1e-12)
    }

    @Test("iris stays sealed through the merge, then opens")
    func irisGating() {
        #expect(LaunchFrame.evaluate(storyTime: 2.5).clipRadius == 0)
        let opening = LaunchFrame.evaluate(storyTime: 2.8)
        #expect(opening.clipRadius > 158)   // hole is growing
        let f = LaunchFrame.evaluate(storyTime: LaunchClock.activeEnd)
        // End scale is the spec's end/target ratio; clip = 158 × that.
        #expect(abs(f.clipRadius - 158.0 * LaunchStageMetrics.specIrisEndScale) < 1e-9)
        #expect(f.ringBlur == 12)
        #expect(f.homeOpacity == 1)
        #expect(f.chromaOpacity == 0)
        #expect(f.mergedOpacity == 0)
    }

    @Test("hold: eddy flow at phase 0 matches the t = 0.9 pose (seamless entry)")
    func holdEntryIsSeamless() {
        let held = LaunchFrame.evaluate(storyTime: 0.9, holdPhase: 0)
        let track = LaunchFrame.evaluate(storyTime: 0.9)
        #expect(abs(held.pairOffset.x - 16) < 1e-12)
        #expect(abs(held.pairOffset.y) < 1e-12)
        #expect(abs(held.twistDegrees) < 1e-12)
        #expect(abs(held.wobble - 0.03) < 1e-12)
        #expect(abs(held.ringScale - track.ringScale) < 1e-12)
    }

    @Test("hold: mid-breath eddy values (flowAmp 0.8)")
    func holdMidBreath() {
        let f = LaunchFrame.evaluate(storyTime: 0.9, holdPhase: 0.5)   // ph = π
        #expect(f.colorMix == 1)                                        // forced chromatic
        #expect(abs(f.pairOffset.x - 16 * 0.7) < 1e-9)                  // 0.85 − 0.15
        #expect(abs(f.pairOffset.y) < 1e-9)                             // sin π
        #expect(abs(f.twistDegrees) < 1e-9)
        #expect(abs(f.wobble - (0.03 + 0.014 * 0.8)) < 1e-9)            // pulse = 1
        #expect(abs(f.ringScale - 1.012) < 1e-9)
        #expect(abs(f.flowPhase - .pi) < 1e-9)
        // The merged ring's basis ignores the flow.
        #expect(f.trackWobble == LaunchFrame.evaluate(storyTime: 0.9).trackWobble)
    }

    @Test("quarter-breath drift: ph = π/2")
    func holdQuarterBreath() {
        let f = LaunchFrame.evaluate(storyTime: 0.9, holdPhase: 0.25)
        #expect(abs(f.pairOffset.x - 16 * 0.85) < 1e-9)
        #expect(abs(f.pairOffset.y - 16 * 0.08) < 1e-9)
        #expect(abs(f.twistDegrees - 1.6 * 0.8) < 1e-9)
    }
}

@Suite("LaunchStageMetrics")
struct LaunchStageMetricsTests {
    @Test("the spec's own canvas round-trips to 9.2")
    func specCanvas() {
        #expect(abs(LaunchStageMetrics.irisTargetScale(width: 1920, height: 1080) - 9.2) < 1e-9)
        #expect(LaunchStageMetrics.unit(width: 1920, height: 1080) == 1)
    }

    @Test("adapted iris clears the corners with the spec's margin on any stage")
    func coverage() {
        for (w, h) in [(402.0, 874.0), (874.0, 402.0), (1024.0, 1366.0), (320.0, 568.0)] {
            let target = LaunchStageMetrics.irisTargetScale(width: w, height: h)
            let clipPoints = target * LaunchStageMetrics.irisInnerRadius
                * LaunchStageMetrics.unit(width: w, height: h)
            let corner = (w * w + h * h).squareRoot() / 2
            // Same relative margin as 9.2 × 158 vs the 16:9 corner (≈ 1.32).
            #expect(abs(clipPoints / corner - 9.2 * 158.0 / 1101.0722733) < 1e-3)
        }
    }
}

@Suite("LaunchRingGeometry")
struct LaunchRingGeometryTests {
    @Test("zero wobble is a true circle")
    func trueCircle() {
        let pts = LaunchRingGeometry.points(
            center: SIMD2(100, 50), radius: 172, turns: 1, wobble: 0, seed: 0.7
        )
        #expect(pts.count == 145)
        for p in pts {
            let d = ((p.x - 100) * (p.x - 100) + (p.y - 50) * (p.y - 50)).squareRoot()
            #expect(abs(d - 172) < 1e-9)
        }
        // turns = 1 seals the path.
        #expect(abs(pts.first!.x - pts.last!.x) < 1e-9)
        #expect(abs(pts.first!.y - pts.last!.y) < 1e-9)
    }

    @Test("wobble stays within the two-harmonic bound")
    func wobbleBounds() {
        let pts = LaunchRingGeometry.points(
            center: .zero, radius: 172, turns: 1.06, wobble: 0.03, seed: 2.4, phase: 1.3
        )
        for p in pts {
            let d = (p.x * p.x + p.y * p.y).squareRoot()
            #expect(d <= 172 * (1 + 0.03 * 1.45) + 1e-9)
            #expect(d >= 172 * (1 - 0.03 * 1.45) - 1e-9)
        }
    }

    @Test("a 2π flow phase loops back to the start pose")
    func phasePeriodicity() {
        let a = LaunchRingGeometry.points(center: .zero, radius: 172, turns: 1.06, wobble: 0.03, seed: 0.7, phase: 0)
        let b = LaunchRingGeometry.points(center: .zero, radius: 172, turns: 1.06, wobble: 0.03, seed: 0.7, phase: 2 * .pi)
        for (p, q) in zip(a, b) {
            #expect(abs(p.x - q.x) < 1e-9)
            #expect(abs(p.y - q.y) < 1e-9)
        }
    }
}

@Suite("LaunchClock")
struct LaunchClockTests {
    @Test("intro runs at half speed straight onto the story clock")
    func intro() {
        let pos = LaunchClock.position(elapsed: 1.0, releasedAtRawTime: nil)
        #expect(pos.storyTime == 0.5)
        #expect(pos.holdPhase == nil)
    }

    @Test("pending work pins the clock and loops breaths")
    func indefiniteHold() {
        // 0.6 raw past the hold = 0.4 of a 1.5 breath.
        let pos = LaunchClock.position(elapsed: 3.0, releasedAtRawTime: nil)
        #expect(pos.storyTime == LaunchClock.holdStart)
        #expect(abs(pos.holdPhase! - 0.4) < 1e-12)
        // Cycle boundary wraps to 0, never reaches 1.
        let wrap = LaunchClock.position(elapsed: 4.8, releasedAtRawTime: nil)
        #expect(abs(wrap.holdPhase!) < 1e-9)
    }

    @Test("fast launch skips the hold entirely (instant mode)")
    func fastLaunchSkipsHold() {
        #expect(LaunchClock.holdLength(releasedAtRawTime: 0.0) == 0)
        #expect(LaunchClock.holdLength(releasedAtRawTime: 0.9) == 0)
        // The story runs straight through the hold point onto the reveal,
        // at the REVEAL pace (1.0 story-s per real s): elapsed 2.0 is 0.2
        // real seconds past the 1.8s intro = story 0.9 + 0.2.
        let through = LaunchClock.position(elapsed: 2.0, releasedAtRawTime: 0.5)
        #expect(abs(through.storyTime - 1.1) < 1e-12)
        #expect(through.holdPhase == nil)
    }

    @Test("a release just after the hold pins still plays the entered breath")
    func releaseJustIntoHold() {
        #expect(LaunchClock.holdLength(releasedAtRawTime: 0.91) == 1.5)
    }

    @Test("release mid-breath completes the current breath")
    func releaseQuantizesUp() {
        #expect(LaunchClock.holdLength(releasedAtRawTime: 1.2) == 1.5)    // 0.3 in → 1 breath
        #expect(LaunchClock.holdLength(releasedAtRawTime: 2.5) == 3.0)    // 1.6 in → 2 breaths
        // A release landing exactly on a boundary doesn't buy an extra breath.
        #expect(LaunchClock.holdLength(releasedAtRawTime: 0.9 + 1.5) == 1.5)
        #expect(LaunchClock.holdLength(releasedAtRawTime: 0.9 + 3.0) == 3.0)
    }

    @Test("completion fires when the resumed clock passes the end")
    func completion() {
        // Instant load (hold skipped): intro 1.8s + reveal 2.55s = 4.35s real.
        // Boundaries probed with 10ms slack — the sum carries FP noise.
        #expect(!LaunchClock.isComplete(elapsed: 4.34, releasedAtRawTime: 0.5))
        #expect(LaunchClock.isComplete(elapsed: 4.36, releasedAtRawTime: 0.5))
        // Mid-breath release: intro 1.8s + breath 3.0s + reveal 2.55s = 7.35s.
        #expect(!LaunchClock.isComplete(elapsed: 7.34, releasedAtRawTime: 1.2))
        #expect(LaunchClock.isComplete(elapsed: 7.36, releasedAtRawTime: 1.2))
        #expect(!LaunchClock.isComplete(elapsed: 1000, releasedAtRawTime: nil))
    }

    @Test("story time clamps at the end and the frame holds the final pose")
    func clampAtEnd() {
        let pos = LaunchClock.position(elapsed: 100, releasedAtRawTime: 0.5)
        #expect(pos.storyTime == LaunchClock.activeEnd)
        #expect(pos.holdPhase == nil)
    }
}
