import Foundation
import Testing
@testable import ParallaxCore

// Curve outputs below are computed from the handoff README's tables with independent formula
// literals — NOT by calling the implementation's easings — so a porting slip in either layer
// fails loudly. Structural values (separations, radii, clock phases) reference the named
// production constant instead, so a token rename can't quietly diverge from the spec.

@Suite("LaunchEase")
struct LaunchEaseTests {
    @Test("endpoints are exact for every curve",
          arguments: [LaunchEase.inOut, .out, .in, .inExpo, .outBack])
    func endpoints(ease: LaunchEase) {
        #expect(abs(ease(0) - 0) < 1e-12)
        #expect(abs(ease(1) - 1) < 1e-12)
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

    @Test("an empty track is flat at zero rather than trapping")
    func emptyTrack() {
        #expect(launchTrack(1.0, []) == 0)
    }
}

@Suite("LaunchFrame")
struct LaunchFrameTests {
    private let iconSep = LaunchStageMetrics.iconSeparation

    @Test("opens exactly on the icon: t = 0")
    func openingPose() {
        let f = LaunchFrame.evaluate(storyTime: 0)
        #expect(f.pairOffset == SIMD2(iconSep, 0))
        #expect(f.wobble == LaunchStageMetrics.baseWobble)
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
        #expect(abs(f.pairOffset.x - (iconSep + 9)) < 1e-12)
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

    @Test("iris stays sealed through the merge, then opens on the expo curve")
    func irisGating() {
        #expect(LaunchFrame.evaluate(storyTime: 2.5).clipRadius == 0)

        // t = 2.8 sits inside the 2.5 → 3.2 expo ramp; the value is deterministic, so pin it
        // rather than merely asserting "bigger than the sealed radius".
        let u = (2.8 - 2.5) / (3.2 - 2.5)
        let expectedScale = 1 + (LaunchStageMetrics.specIrisTargetScale - 1) * pow(2, 10 * u - 10)
        let opening = LaunchFrame.evaluate(storyTime: 2.8)
        #expect(abs(opening.clipRadius - LaunchStageMetrics.irisInnerRadius * expectedScale) < 1e-9)
        #expect(opening.clipRadius > LaunchStageMetrics.irisInnerRadius)

        let f = LaunchFrame.evaluate(storyTime: LaunchClock.activeEnd)
        // End scale is the spec's end/target ratio applied to the inner radius.
        let endRadius = LaunchStageMetrics.irisInnerRadius * LaunchStageMetrics.specIrisEndScale
        #expect(abs(f.clipRadius - endRadius) < 1e-9)
        #expect(f.ringBlur == 12)
        #expect(f.homeOpacity == 1)
        #expect(f.chromaOpacity == 0)
        #expect(f.mergedOpacity == 0)
    }

    @Test("a stage-adapted iris target scales the end radius with it")
    func irisFollowsTheAdaptedTarget() {
        let adapted = 6.0
        let f = LaunchFrame.evaluate(storyTime: LaunchClock.activeEnd, irisTargetScale: adapted)
        let ratio = LaunchStageMetrics.specIrisEndScale / LaunchStageMetrics.specIrisTargetScale
        #expect(abs(f.clipRadius - LaunchStageMetrics.irisInnerRadius * adapted * ratio) < 1e-9)
    }

    @Test("hold: eddy flow at phase 0 matches the hold-start pose (seamless entry)")
    func holdEntryIsSeamless() {
        let held = LaunchFrame.evaluate(storyTime: LaunchClock.holdStart, holdPhase: 0)
        let track = LaunchFrame.evaluate(storyTime: LaunchClock.holdStart)
        #expect(abs(held.pairOffset.x - iconSep) < 1e-12)
        #expect(abs(held.pairOffset.y) < 1e-12)
        #expect(abs(held.twistDegrees) < 1e-12)
        #expect(abs(held.wobble - LaunchStageMetrics.baseWobble) < 1e-12)
        #expect(abs(held.ringScale - track.ringScale) < 1e-12)
    }

    @Test("hold: mid-breath eddy values")
    func holdMidBreath() {
        let k = LaunchClock.flowAmplitude
        let f = LaunchFrame.evaluate(storyTime: LaunchClock.holdStart, holdPhase: 0.5)   // ph = π
        #expect(f.colorMix == 1)                                        // forced chromatic
        #expect(abs(f.pairOffset.x - iconSep * 0.7) < 1e-9)             // 0.85 − 0.15
        #expect(abs(f.pairOffset.y) < 1e-9)                             // sin π
        #expect(abs(f.twistDegrees) < 1e-9)
        #expect(abs(f.wobble - (LaunchStageMetrics.baseWobble + 0.014 * k)) < 1e-9)   // pulse = 1
        #expect(abs(f.ringScale - 1.012) < 1e-9)
        #expect(abs(f.flowPhase - .pi) < 1e-9)
        // The merged ring's basis ignores the flow.
        #expect(f.trackWobble == LaunchFrame.evaluate(storyTime: LaunchClock.holdStart).trackWobble)
    }

    @Test("quarter-breath drift: ph = π/2")
    func holdQuarterBreath() {
        let f = LaunchFrame.evaluate(storyTime: LaunchClock.holdStart, holdPhase: 0.25)
        #expect(abs(f.pairOffset.x - iconSep * 0.85) < 1e-9)
        #expect(abs(f.pairOffset.y - iconSep * 0.08) < 1e-9)
        #expect(abs(f.twistDegrees - 1.6 * LaunchClock.flowAmplitude) < 1e-9)
    }

    /// Every term of the eddy is periodic in the phase, which is what lets the hold loop
    /// indefinitely without a visible seam at the cycle boundary.
    @Test("hold: phase 1 reproduces phase 0 exactly")
    func holdLoopsSeamlessly() {
        let start = LaunchFrame.evaluate(storyTime: LaunchClock.holdStart, holdPhase: 0)
        let wrapped = LaunchFrame.evaluate(storyTime: LaunchClock.holdStart, holdPhase: 1)
        #expect(abs(start.pairOffset.x - wrapped.pairOffset.x) < 1e-9)
        #expect(abs(start.pairOffset.y - wrapped.pairOffset.y) < 1e-9)
        #expect(abs(start.twistDegrees - wrapped.twistDegrees) < 1e-9)
        #expect(abs(start.wobble - wrapped.wobble) < 1e-9)
        #expect(abs(start.ringScale - wrapped.ringScale) < 1e-9)
    }
}

@Suite("LaunchStageMetrics")
struct LaunchStageMetricsTests {
    @Test("the spec's own canvas round-trips to the authored target scale")
    func specCanvas() {
        let adapted = LaunchStageMetrics.irisTargetScale(width: 1920, height: 1080)
        #expect(abs(adapted - LaunchStageMetrics.specIrisTargetScale) < 1e-9)
        #expect(LaunchStageMetrics.unit(width: 1920, height: 1080) == 1)
    }

    @Test("unit scales off the stage's minimum dimension")
    func unitScalesOffMinDimension() {
        let half = LaunchStageMetrics.referenceMinDimension / 2
        #expect(LaunchStageMetrics.unit(width: 1920, height: half) == 0.5)
        #expect(LaunchStageMetrics.unit(width: half, height: 1920) == 0.5)
    }

    @Test("adapted iris clears the corners with the spec's margin on any stage",
          arguments: [(402.0, 874.0), (874.0, 402.0), (1024.0, 1366.0), (320.0, 568.0)])
    func coverage(width: Double, height: Double) {
        let target = LaunchStageMetrics.irisTargetScale(width: width, height: height)
        let clipPoints = target * LaunchStageMetrics.irisInnerRadius
            * LaunchStageMetrics.unit(width: width, height: height)
        let corner = (width * width + height * height).squareRoot() / 2
        let specCorner = (1920.0 * 1920.0 + 1080.0 * 1080.0).squareRoot() / 2
        let specMargin = LaunchStageMetrics.specIrisTargetScale
            * LaunchStageMetrics.irisInnerRadius / specCorner
        #expect(abs(clipPoints / corner - specMargin) < 1e-9)
    }
}

@Suite("LaunchRingGeometry")
struct LaunchRingGeometryTests {
    private let radius = LaunchStageMetrics.ringRadius
    private let wobble = LaunchStageMetrics.baseWobble

    @Test("zero wobble is a true circle")
    func trueCircle() {
        let center = SIMD2(100.0, 50.0)
        let pts = LaunchRingGeometry.points(
            center: center, radius: radius, turns: 1, wobble: 0, seed: LaunchStageMetrics.mainSeed
        )
        #expect(pts.count == 145)   // the default 144 segments, inclusive of both ends
        for p in pts {
            let d = ((p.x - center.x) * (p.x - center.x) + (p.y - center.y) * (p.y - center.y)).squareRoot()
            #expect(abs(d - radius) < 1e-9)
        }
        // turns = 1 seals the path.
        #expect(abs(pts[0].x - pts[pts.count - 1].x) < 1e-9)
        #expect(abs(pts[0].y - pts[pts.count - 1].y) < 1e-9)
    }

    @Test("the segment count controls the polyline resolution", arguments: [8, 36, 144, 360])
    func segmentCount(segments: Int) {
        let pts = LaunchRingGeometry.points(
            center: .zero, radius: radius, turns: 1, wobble: 0,
            seed: LaunchStageMetrics.mainSeed, segments: segments
        )
        #expect(pts.count == segments + 1)
    }

    @Test("wobble stays within the two-harmonic bound")
    func wobbleBounds() {
        let pts = LaunchRingGeometry.points(
            center: .zero, radius: radius, turns: 1.06, wobble: wobble,
            seed: LaunchStageMetrics.ghostSeed, phase: 1.3
        )
        // The two harmonics have amplitudes 1 and 0.45 → the envelope is ±1.45 × wobble.
        for p in pts {
            let d = (p.x * p.x + p.y * p.y).squareRoot()
            #expect(d <= radius * (1 + wobble * 1.45) + 1e-9)
            #expect(d >= radius * (1 - wobble * 1.45) - 1e-9)
        }
    }

    @Test("a 2π flow phase loops back to the start pose")
    func phasePeriodicity() {
        let a = LaunchRingGeometry.points(center: .zero, radius: radius, turns: 1.06,
                                          wobble: wobble, seed: LaunchStageMetrics.mainSeed, phase: 0)
        let b = LaunchRingGeometry.points(center: .zero, radius: radius, turns: 1.06,
                                          wobble: wobble, seed: LaunchStageMetrics.mainSeed, phase: 2 * .pi)
        for (p, q) in zip(a, b) {
            #expect(abs(p.x - q.x) < 1e-9)
            #expect(abs(p.y - q.y) < 1e-9)
        }
    }

    /// `turns` > 1 is the pencil's overshoot tail: the path must NOT close.
    @Test("turns above 1 leaves the overshoot tail open")
    func overshootTailIsOpen() {
        let pts = LaunchRingGeometry.points(
            center: .zero, radius: radius, turns: 1.06, wobble: 0, seed: LaunchStageMetrics.mainSeed
        )
        let first = pts[0], last = pts[pts.count - 1]
        let gap = ((first.x - last.x) * (first.x - last.x) + (first.y - last.y) * (first.y - last.y)).squareRoot()
        #expect(gap > 1e-6)
    }
}

@Suite("LaunchClock")
struct LaunchClockTests {
    @Test("intro runs at the intro speed straight onto the story clock")
    func intro() {
        let elapsed = 1.0
        let pos = LaunchClock.position(elapsed: elapsed, releasedAtRawTime: nil)
        #expect(pos.storyTime == elapsed * LaunchClock.speed)
        #expect(pos.holdPhase == nil)
    }

    @Test("rawTime maps real seconds onto the intro-domain story clock")
    func rawTimeIsTheIntroPace() {
        #expect(LaunchClock.rawTime(elapsed: 2.0) == 2.0 * LaunchClock.speed)
        #expect(LaunchClock.rawTime(elapsed: 0) == 0)
    }

    @Test("pending work pins the clock and loops breaths")
    func indefiniteHold() {
        let elapsed = 3.0
        let raw = elapsed * LaunchClock.speed
        let pos = LaunchClock.position(elapsed: elapsed, releasedAtRawTime: nil)
        #expect(pos.storyTime == LaunchClock.holdStart)
        let expectedPhase = (raw - LaunchClock.holdStart) / LaunchClock.breathLength
        #expect(abs((pos.holdPhase ?? -1) - expectedPhase) < 1e-12)

        // A cycle boundary wraps to 0, never reaches 1.
        let boundary = (LaunchClock.holdStart + LaunchClock.breathLength) / LaunchClock.speed
        let wrap = LaunchClock.position(elapsed: boundary, releasedAtRawTime: nil)
        #expect(abs(wrap.holdPhase ?? -1) < 1e-9)
    }

    @Test("fast launch skips the hold entirely (instant mode)")
    func fastLaunchSkipsHold() {
        #expect(LaunchClock.holdLength(releasedAtRawTime: 0.0) == 0)
        #expect(LaunchClock.holdLength(releasedAtRawTime: LaunchClock.holdStart) == 0)

        // The story runs straight through the hold point onto the reveal, at the REVEAL pace:
        // 0.2 real seconds past the intro is holdStart + 0.2 × revealSpeed of story.
        let introReal = LaunchClock.holdStart / LaunchClock.speed
        let past = 0.2
        let through = LaunchClock.position(elapsed: introReal + past, releasedAtRawTime: 0.5)
        #expect(abs(through.storyTime - (LaunchClock.holdStart + past * LaunchClock.revealSpeed)) < 1e-12)
        #expect(through.holdPhase == nil)
    }

    @Test("a release just after the hold pins still plays the entered breath")
    func releaseJustIntoHold() {
        #expect(LaunchClock.holdLength(releasedAtRawTime: LaunchClock.holdStart + 0.01)
                == LaunchClock.breathLength)
    }

    @Test("release mid-breath completes the current breath")
    func releaseQuantizesUp() {
        let hold = LaunchClock.holdStart, breath = LaunchClock.breathLength
        #expect(LaunchClock.holdLength(releasedAtRawTime: hold + 0.3 * breath) == breath)
        #expect(LaunchClock.holdLength(releasedAtRawTime: hold + 1.1 * breath) == 2 * breath)
        // A release landing exactly on a boundary doesn't buy an extra breath.
        #expect(LaunchClock.holdLength(releasedAtRawTime: hold + breath) == breath)
        #expect(LaunchClock.holdLength(releasedAtRawTime: hold + 2 * breath) == 2 * breath)
    }

    @Test("completion fires when the resumed clock passes the end")
    func completion() {
        let introReal = LaunchClock.holdStart / LaunchClock.speed
        let revealReal = (LaunchClock.activeEnd - LaunchClock.holdStart) / LaunchClock.revealSpeed

        // Instant load (hold skipped). Boundaries probed with 10ms slack — the sum carries FP noise.
        let instant = introReal + revealReal
        #expect(LaunchClock.isComplete(elapsed: instant - 0.01, releasedAtRawTime: 0.5) == false)
        #expect(LaunchClock.isComplete(elapsed: instant + 0.01, releasedAtRawTime: 0.5))

        // Mid-breath release: one whole breath is inserted before the reveal.
        let releasedAt = LaunchClock.holdStart + 0.3 * LaunchClock.breathLength
        let held = introReal
            + LaunchClock.holdLength(releasedAtRawTime: releasedAt) / LaunchClock.speed
            + revealReal
        #expect(LaunchClock.isComplete(elapsed: held - 0.01, releasedAtRawTime: releasedAt) == false)
        #expect(LaunchClock.isComplete(elapsed: held + 0.01, releasedAtRawTime: releasedAt))

        // Work still pending: the hold loops forever, so the story can never be complete.
        #expect(LaunchClock.isComplete(elapsed: 1000, releasedAtRawTime: nil) == false)
    }

    @Test("story time clamps at the end and the frame holds the final pose")
    func clampAtEnd() {
        let pos = LaunchClock.position(elapsed: 100, releasedAtRawTime: 0.5)
        #expect(pos.storyTime == LaunchClock.activeEnd)
        #expect(pos.holdPhase == nil)
    }

    @Test("the settle window is shared with the host, in real seconds at the reveal pace")
    func settleRealDuration() {
        let expected = (LaunchClock.settleEnd - LaunchClock.settleStart) / LaunchClock.revealSpeed
        #expect(LaunchClock.settleRealDuration == expected)
        #expect(LaunchClock.settleStart < LaunchClock.settleEnd)
        #expect(LaunchClock.settleEnd <= LaunchClock.activeEnd)
    }
}
