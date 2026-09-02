import Foundation
import SwiftUI
import Testing
@testable import Parallax

/// The pulse's two pure pieces: the span it draws (`SeekDelta`) and the ramp it draws it on
/// (`ScrubDeltaPulse.phase`). Everything else in that view is pixels, and belongs to the
/// `PlayerProgressBar` diagnostic preview.
@MainActor
@Suite("ScrubDeltaPulse — the scrub delta's span and sweep")
struct ScrubDeltaPulseTests {

    /// Direction is the sign of the jump, and the drawn span is direction-free — a backward
    /// seek's segment sits between B and A exactly as a forward one sits between A and B.
    @Test("the span is unordered, the direction is signed", arguments: [
        (SeekDelta(from: 0.28, to: 0.72), true),
        (SeekDelta(from: 0.72, to: 0.28), false),
    ] as [(SeekDelta, Bool)])
    func spanAndDirection(delta: SeekDelta, isForward: Bool) {
        #expect(delta.isForward == isForward)
        #expect(delta.lower == 0.28)
        #expect(delta.upper == 0.72)
    }

    /// A zero-length jump still reads FORWARD rather than trapping: nothing about a
    /// degenerate span should need a third direction, and the view drops it on width anyway.
    @Test("a zero-length delta is forward and spans nothing")
    func degenerateDelta() {
        let delta = SeekDelta(from: 0.5, to: 0.5)
        #expect(delta.isForward)
        #expect(delta.lower == delta.upper)
    }

    /// The ramp is a saw: 0 at the anchor, climbing to 1 over one sweep, wrapping cleanly.
    /// The wrap is only invisible because the comet has cleared the segment by then — so the
    /// value that matters is that the ramp never stalls or runs backward across a cycle edge.
    @Test("the sweep phase ramps 0→1 and wraps", arguments: [
        (0.0, 0.0),
        (ScrubDeltaPulse.sweepSeconds / 4, 0.25),
        (ScrubDeltaPulse.sweepSeconds * 0.999, 0.999),
        (ScrubDeltaPulse.sweepSeconds, 0.0),
        (ScrubDeltaPulse.sweepSeconds * 2.5, 0.5),
    ] as [(TimeInterval, Double)])
    func sweepPhaseRamps(elapsed: TimeInterval, expected: Double) {
        let start = Date(timeIntervalSinceReferenceDate: 1_000)
        let phase = ScrubDeltaPulse.phase(at: start.addingTimeInterval(elapsed), since: start)
        #expect(abs(phase - expected) < 0.0001)
    }

    /// The settle breath rides the SAME phase as the comet, so the two readings of "still
    /// landing" are one clock: one swell per pass, dark at the phase edges where the comet is
    /// off the segment, brightest as it crosses the middle.
    @Test("the settle breath swells once per sweep and closes at the wrap")
    func breathIsOnePerSweep() {
        let atEdges = [0.0, 1.0].map(ScrubDeltaPulse.breath(atPhase:))
        #expect(atEdges.allSatisfy { abs($0 - atEdges[0]) < 0.0001 },
                "the wrap must not step — the sweep restarts at phase 0 every pass")
        let peak = ScrubDeltaPulse.breath(atPhase: 0.5)
        #expect(peak > atEdges[0])
        let rising = stride(from: 0.0, through: 0.5, by: 0.05)
            .map(ScrubDeltaPulse.breath(atPhase:))
        #expect(zip(rising, rising.dropFirst()).allSatisfy { $0 <= $1 })
    }

    /// It plays directly under the scrub bubble, so it is allowed to be felt and not seen. An
    /// opacity that ever climbed into the double digits would start competing with the readout.
    @Test("the breath stays subliminal", arguments: stride(from: 0.0, through: 1.0, by: 0.05).map { $0 })
    func breathStaysFaint(phase: Double) {
        let breath = ScrubDeltaPulse.breath(atPhase: phase)
        #expect(breath > 0 && breath <= 0.12)
    }

    /// A view that outlives its anchor (a `sweepStart` stamped before a clock change) must
    /// still produce a phase in range rather than a negative offset that parks the comet.
    @Test("a date before the anchor still yields a 0..<1 phase")
    func phaseStaysInRangeBeforeTheAnchor() {
        let start = Date(timeIntervalSinceReferenceDate: 1_000)
        let phase = ScrubDeltaPulse.phase(at: start.addingTimeInterval(-0.3), since: start)
        #expect(phase >= 0 && phase < 1)
    }
}

/// The concrete indicator's crossing: the offset it is held back by, the ghost it dissolves
/// into, and the timing relationship that makes the comet a trail rather than a leader.
/// Everything else about the travel is a SwiftUI animation, and belongs to the diagnostic
/// previews in `PlayerProgressBar`.
@MainActor
@Suite("ScrubTravel — the concrete indicator's crossing to the virtual one")
struct ScrubTravelTests {

    private static let forward = SeekDelta(from: 0.28, to: 0.72)
    private static let backward = SeekDelta(from: 0.72, to: 0.28)
    private static let width: CGFloat = 1_000

    /// The crossing has to finish inside one comet sweep, or the thing billed as the dot's
    /// trail arrives first. Everything about the two durations' relationship hangs on this.
    @Test("one crossing is shorter than one comet sweep")
    func crossingOutrunsTheSweep() {
        #expect(ScrubTravel.seconds > 0)
        #expect(ScrubTravel.seconds < ScrubDeltaPulse.sweepSeconds)
    }

    /// The travel is an offset that ends at ZERO, not a mirrored position — which is what
    /// keeps the bar's resting position a pure function of its inputs. Start of the crossing
    /// = the full displacement back to A; end = nothing at all.
    @Test("the crossing starts at the full displacement back to A and ends at nothing",
          arguments: [forward, backward])
    func offsetRunsFromParkToZero(delta: SeekDelta) {
        let park = ScrubTravel.parkOffset(delta, width: Self.width)
        #expect(abs(park - CGFloat(delta.from - delta.to) * Self.width) < 0.0001)
        #expect(abs(ScrubTravel.offset(delta, width: Self.width, progress: 0) - park) < 0.0001)
        #expect(ScrubTravel.offset(delta, width: Self.width, progress: 1) == 0)
        #expect(abs(ScrubTravel.offset(delta, width: Self.width, progress: 0.5) - park / 2) < 0.0001)
    }

    /// The displacement is SIGNED: a forward jump holds the indicator to the left of the
    /// destination the bar already draws, a backward one to its right. Without the sign the
    /// crossing would run the wrong way for half of all seeks.
    @Test("the displacement's sign is the seek's direction, inverted")
    func displacementIsSigned() {
        #expect(ScrubTravel.parkOffset(Self.forward, width: Self.width) < 0)
        #expect(ScrubTravel.parkOffset(Self.backward, width: Self.width) > 0)
        #expect(ScrubTravel.parkOffset(SeekDelta(from: 0.5, to: 0.5), width: Self.width) == 0)
    }

    /// Out-of-range progress can only come from a pinned preview, and it must clamp rather
    /// than fling the indicator past either end.
    @Test("progress outside 0...1 clamps to the two ends", arguments: [-1.0, -0.01, 1.01, 4.0])
    func offsetClampsItsProgress(progress: Double) {
        let offset = ScrubTravel.offset(Self.forward, width: Self.width, progress: progress)
        let park = ScrubTravel.parkOffset(Self.forward, width: Self.width)
        #expect(offset == (progress < 0 ? park : 0))
    }

    /// The ghost dissolves as the concrete indicator ARRIVES: it is the destination marker,
    /// so it stays fully legible for the first half of the crossing and is gone at touchdown.
    /// Anything else leaves the dot travelling toward nothing.
    @Test("the ghost holds through the first half of the crossing and is gone on arrival",
          arguments: [(0.0, 1.0), (0.25, 1.0), (0.5, 1.0), (0.75, 0.5), (1.0, 0.0)] as [(Double, Double)])
    func ghostDissolvesOnArrival(progress: Double, expected: Double) {
        #expect(abs(ScrubTravel.ghostOpacity(atTravel: progress) - expected) < 0.0001)
    }

    /// The arrival flare is the landing, so it has to be dark for the approach and full at
    /// touchdown. A bloom that was already lit at departure would read as the indicator being
    /// lit for the whole journey, which says nothing about where it ends up.
    @Test("the arrival flare stays dark through the approach and peaks on touchdown",
          arguments: [(0.0, 0.0), (0.35, 0.0), (ScrubTravel.bloomOnset, 0.0), (0.85, 0.5), (1.0, 1.0)]
            as [(Double, Double)])
    func bloomLightsOnArrival(progress: Double, expected: Double) {
        #expect(abs(ScrubTravel.bloom(atTravel: progress) - expected) < 0.0001)
    }

    /// It only ever swells: a flare that dipped mid-rise would read as two landings.
    @Test("the flare never dims on the way in")
    func bloomIsMonotone() {
        let samples = stride(from: 0.0, through: 1.0, by: 0.05)
            .map { ScrubTravel.bloom(atTravel: $0) }
        #expect(zip(samples, samples.dropFirst()).allSatisfy { $0 <= $1 })
    }

    /// Out-of-range progress is preview-only, and it must clamp rather than overdrive the flare
    /// past full or drive it negative.
    @Test("flare progress outside 0...1 clamps", arguments: [-4.0, -0.01, 1.01, 9.0])
    func bloomClampsItsProgress(progress: Double) {
        let bloom = ScrubTravel.bloom(atTravel: progress)
        #expect(bloom == (progress < 0 ? 0 : 1))
    }

    /// The flare belongs to the crossing that produced it, and `ScrubIndicators` starts its
    /// decay exactly one crossing after the landing — so the decay itself has to fit inside a
    /// crossing, or a second scrub arriving on the heels of the first would find the flare from
    /// the first still burning and the two would read as one long glow.
    @Test("the flare's decay fits inside the crossing that lit it")
    func bloomDecayIsBounded() {
        #expect(ScrubTravel.bloomOnset > 0 && ScrubTravel.bloomOnset < 1)
        #expect(ScrubTravel.bloomFadeSeconds > 0)
        #expect(ScrubTravel.bloomFadeSeconds <= ScrubTravel.seconds)
    }

    /// The dissolve is monotone — a ghost that brightened again mid-crossing would read as a
    /// second indicator arriving rather than one being absorbed.
    @Test("the dissolve never runs backward")
    func ghostDissolveIsMonotone() {
        let samples = stride(from: 0.0, through: 1.0, by: 0.05)
            .map { ScrubTravel.ghostOpacity(atTravel: $0) }
        #expect(zip(samples, samples.dropFirst()).allSatisfy { $0 >= $1 })
    }

    /// The concrete indicator earns its crossing when the seek LANDS, which is the beat the model
    /// drops the flight on — so the bar has to park it on a span the model no longer publishes.
    @Test("the concrete indicator is parked at A for the whole flight and until its crossing launches")
    func parkedSpanFollowsTheFlightThenTheRetainedCopy() {
        let span = SeekSpan(id: 7, delta: Self.forward)
        #expect(ScrubTravel.parked(flight: span, retained: nil, launched: nil) == span, "in flight: at A")
        #expect(ScrubTravel.parked(flight: span, retained: span, launched: nil) == span)
        #expect(ScrubTravel.parked(flight: nil, retained: span, launched: nil) == span,
                "landed, crossing not launched yet: still at A")
        #expect(ScrubTravel.parked(flight: nil, retained: span, launched: 7) == nil,
                "crossing launched: the offset animates to B")
        #expect(ScrubTravel.parked(flight: nil, retained: nil, launched: nil) == nil)
        #expect(ScrubTravel.parked(flight: span, retained: span, launched: 7) == nil,
                "a flight whose crossing already launched is not re-parked")
        let newer = SeekSpan(id: 8, delta: Self.backward)
        #expect(ScrubTravel.parked(flight: newer, retained: span, launched: 7) == newer,
                "a new flight parks on its own A")
    }

    @Test("the landing linger covers the crossing and the flare's decay")
    func landingLingerCoversTheCrossing() {
        #expect(ScrubTravel.landingSeconds >= ScrubTravel.seconds + ScrubTravel.bloomFadeSeconds)
        #expect(ScrubTravel.landingSeconds >= ScrubTravel.seconds + ScrubDeltaPulse.fadeSeconds,
                "…and the comet's trailing sweep plus its fade")
    }

}

/// The band's one compositing rule: ink over the played fill, lift over bare track, split at
/// the fill's own edge. The two forms the device review approved are the two ENDS of it.
@MainActor
@Suite("ScrubSpanBand — the split at the played fill's edge")
struct ScrubSpanBandTests {

    private static let span = SeekDelta(from: 0.28, to: 0.72)

    /// A settled forward jump: the fill has arrived at B, so the whole span lies inside it and
    /// the band is all ink — the fill reading as provisional.
    @Test("a fill past the span's end inks the whole band")
    func fillCoveringTheSpanIsAllInk() {
        #expect(ScrubSpanBand<EmptyView>.splitLocation(span: Self.span, fillEdge: 0.72) == 1)
        #expect(ScrubSpanBand<EmptyView>.splitLocation(span: Self.span, fillEdge: 0.95) == 1)
    }

    /// A settled backward jump: the fill sits at B, below the span, so the whole band lies on
    /// bare track and is all lift.
    @Test("a fill short of the span's start lifts the whole band")
    func fillBeforeTheSpanIsAllLift() {
        #expect(ScrubSpanBand<EmptyView>.splitLocation(span: Self.span, fillEdge: 0.28) == 0)
        #expect(ScrubSpanBand<EmptyView>.splitLocation(span: Self.span, fillEdge: 0.0) == 0)
    }

    /// The case the travel introduced and the old two-case rule could not express: the fill's
    /// edge is INSIDE the span, because the concrete indicator is dragging it across.
    @Test("a fill edge inside the span splits it there", arguments: [
        (0.39, 0.25), (0.50, 0.5), (0.61, 0.75),
    ] as [(Double, Double)])
    func aMovingFillEdgeSplitsTheBand(fillEdge: Double, expected: Double) {
        let split = ScrubSpanBand<EmptyView>.splitLocation(span: Self.span, fillEdge: fillEdge)
        #expect(abs(split - expected) < 0.0001)
    }

    /// The gradient is two flat tints meeting on a hard edge, so the stops have to be four
    /// with a duplicated location — anything else smears the join across the band.
    @Test("the stops are two flat tints meeting on the split")
    func stopsAreAHardEdge() {
        let stops = ScrubSpanBand<EmptyView>.stops(span: Self.span, fillEdge: 0.5, intensity: 1)
        #expect(stops.count == 4)
        #expect(stops[0].location == 0)
        #expect(stops[1].location == stops[2].location)
        #expect(stops[3].location == 1)
    }

    /// A degenerate span (a commit that went nowhere, a drag that hasn't moved) must resolve
    /// to a side rather than divide by zero. The view drops it on width anyway.
    @Test("a zero-width span picks a side instead of dividing by zero")
    func degenerateSpanResolves() {
        let point = SeekDelta(from: 0.5, to: 0.5)
        #expect(ScrubSpanBand<EmptyView>.splitLocation(span: point, fillEdge: 0.5) == 1)
        #expect(ScrubSpanBand<EmptyView>.splitLocation(span: point, fillEdge: 0.2) == 0)
    }

    /// One minimum for both callers: below it there is nothing to sweep and nothing to
    /// differentiate, and a few points of tint beside the handle reads as an artifact.
    @Test("the minimum span scales with the platform unit")
    func minimumSpanScales() {
        #expect(ScrubSpanBand<EmptyView>.minimumSpan(unit: 1) == 5)
        #expect(ScrubSpanBand<EmptyView>.minimumSpan(unit: 2) == 10)
    }
}
