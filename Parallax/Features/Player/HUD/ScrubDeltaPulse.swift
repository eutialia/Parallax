import SwiftUI

/// The span a committed-but-unlanded seek covers, as the two 0...1 track fractions the
/// playhead jumped between: `from` is where the bar sat when the commit landed (A), `to` is
/// the committed target (B). The sign of `to - from` IS the seek's direction, and a re-scrub
/// mid-flight yields a fresh pair anchored at wherever the bar had got to — so the pair alone
/// describes the whole animation. Built by `PlayerViewModel.seekSpan` off the live `SeekFlight`,
/// which carries the identity these fractions deliberately don't.
///
/// Doubles as the drag's live span (concrete → virtual), which is the same shape of fact:
/// two fractions and the direction between them.
struct SeekDelta: Equatable {
    var from: Double
    var to: Double

    var isForward: Bool { to >= from }
    var lower: Double { min(from, to) }
    var upper: Double { max(from, to) }
}

extension EnvironmentValues {
    /// Pins the scrub indicators into one renderable state, bypassing the pulse's arming
    /// delay, its live sweep, and the travel/dissolve animations. Nil (the default)
    /// everywhere in the app — this is the render hook, and it exists because none of the
    /// states the diagnostic previews need is otherwise reachable from a snapshot: a
    /// one-frame render of the live sweep catches phase 0 (comet entirely off the segment),
    /// the travel is over before a second frame exists, and `accessibilityReduceMotion` is a
    /// read-only environment value.
    @Entry var seekPulsePreview: ScrubDeltaPulse.PreviewState? = nil
}

/// The concrete indicator's commit-time journey: the constants, and the pure geometry both
/// the live animation and its diagnostic preview resolve against.
///
/// The model this serves: while a finger (or a tvOS swipe) previews a seek, the bar carries
/// TWO indicators — the CONCRETE one, still on the paused playback position, and a VIRTUAL
/// ghost of it riding the gesture. On commit the concrete one travels to where the virtual
/// stands and the virtual dissolves into it, so the jump is something the eye follows rather
/// than something it has to reconstruct from a teleport.
enum ScrubTravel {
    /// One A→B crossing by the concrete indicator, end to end. A fixed DURATION for the same
    /// reason `ScrubDeltaPulse.sweepSeconds` is one: a commit is a single gesture, and it
    /// should read as a single traversal whether it jumped a minute or two hours — a
    /// speed-based glide would spend seconds crawling across a long seek.
    ///
    /// Deliberately SHORTER than one comet sweep. The comet is the travel's trail, so the dot
    /// has to arrive while the sweep is still crossing; at parity (and worse, longer) the
    /// comet would run ahead of the thing it is supposed to be following.
    static let seconds: TimeInterval = ScrubDeltaPulse.sweepSeconds * 0.6

    /// Emphasized decelerate: leaves A immediately (the commit must feel instant) and settles
    /// onto B rather than stopping dead on it.
    static let curve: Animation = .timingCurve(0.2, 0, 0, 1, duration: seconds)

    /// The ghost dissolves as the concrete indicator ARRIVES, not as it departs. The virtual
    /// indicator is the DESTINATION marker: dropping it at departure would leave the dot
    /// crossing toward nothing, and the whole point of the travel is that the eye has
    /// somewhere to look. Holding it to touchdown makes the handoff read as the solid
    /// indicator absorbing the ghost it was aiming at.
    static let dissolveDelay: TimeInterval = seconds * 0.5
    static let dissolveSeconds: TimeInterval = seconds * 0.5
    /// `easeIn` on a fade-OUT keeps the ghost legible through the crossing and takes it away
    /// quickly at the end, so the two never sit on top of each other as a double image.
    static let dissolve: Animation = .easeIn(duration: dissolveSeconds).delay(dissolveDelay)

    /// Where in the crossing the arrival flare starts to swell. Late on purpose: a bloom that
    /// rises from departure would read as the indicator being lit for the whole journey, when
    /// what it has to say is "it landed HERE".
    static let bloomOnset = 0.7
    /// How long the flare takes to go out once it has peaked. Longer than its rise — light
    /// decays, it doesn't switch off.
    static let bloomFadeSeconds: TimeInterval = seconds * 0.9
    static let bloomRise: Animation =
        .easeOut(duration: seconds * (1 - bloomOnset)).delay(seconds * bloomOnset)
    static let bloomFall: Animation = .easeOut(duration: bloomFadeSeconds)

    /// The flare's strength at a travel `progress` — the same ramp `bloomRise` runs, as a pure
    /// function so a static render can catch it mid-swell. Zero for the whole approach, full at
    /// touchdown; the decay afterwards is the live animation's business, not the crossing's.
    static func bloom(atTravel progress: Double) -> Double {
        let p = progress.unitClamped
        guard p > bloomOnset else { return 0 }
        return (p - bloomOnset) / (1 - bloomOnset)
    }

    /// The displacement that puts the concrete indicator back at A while the bar is already
    /// drawing B. The travel is expressed as an OFFSET that animates to zero rather than as a
    /// mirrored position, and that is the load-bearing choice: at rest the offset is exactly
    /// zero, so the bar's position expression stays a pure function of its inputs and the
    /// caller's own position animation (the mini bar's click-seek spring, the tvOS 1:1 pin)
    /// keeps owning the playhead.
    static func parkOffset(_ delta: SeekDelta, width: CGFloat) -> CGFloat {
        CGFloat(delta.from - delta.to) * width
    }

    /// The offset at a given travel `progress` (0 = still at A, 1 = arrived at B). The
    /// preview hook's only arithmetic.
    static func offset(_ delta: SeekDelta, width: CGFloat, progress: Double) -> CGFloat {
        parkOffset(delta, width: width) * (1 - progress.unitClamped)
    }

    /// The ghost's opacity at a travel `progress` — the same hold-then-fade the live
    /// animation runs, sampled so a static render can show the crossing mid-flight.
    static func ghostOpacity(atTravel progress: Double) -> Double {
        guard dissolveSeconds > 0 else { return 0 }
        let elapsed = progress.unitClamped * seconds
        return 1 - ((elapsed - dissolveDelay) / dissolveSeconds).unitClamped
    }
}

/// The tinted stretch between two points on the track: the drag's concrete→virtual gap, and
/// the committed jump's A→B span under `ScrubDeltaPulse`.
///
/// ONE compositing rule covers every case, because a band is only ever legible against what
/// it sits on: it is INK where it lies over the solid played fill and a LIFT where it lies
/// over bare track, split at the fill's own edge. That rule reduces to the two forms the
/// device review approved — a settled forward jump is entirely inside the fill (all ink, the
/// fill reading as provisional), a settled backward one is entirely past it (all lift, a band
/// brighter than the track vacating) — and it is also the only rule that survives the fill
/// EDGE MOVING, which is exactly what the concrete indicator's travel does to it.
struct ScrubSpanBand<Overlay: View>: View {
    let span: SeekDelta
    /// The played fill's leading edge as a 0...1 track fraction — where the band flips from
    /// ink to lift.
    let fillEdge: Double
    /// The track's full span in points; the 0...1 fractions resolve against it.
    let width: CGFloat
    let height: CGFloat
    /// `PlayerMetrics.u` — the phone/tv scale the minimum span rides.
    let unit: CGFloat
    /// Scales both tints. The drag preview runs under 1 so the band never competes with the
    /// scrub bubble sitting directly above it; the in-flight pulse runs at full strength.
    var intensity: Double = 1
    /// The provisional hue. It colours the LIFT half (the band over bare track); the ink half
    /// stays ink, because ink is a shadow over the played fill and shadows aren't tinted.
    /// `.white` is the monochrome bar, unchanged.
    var accent: Color = .white
    @ViewBuilder var overlay: () -> Overlay

    /// Narrower than this there is nothing to differentiate and nothing to sweep — a few
    /// points of tint next to the handle reads as a rendering artifact, not as a span.
    static func minimumSpan(unit: CGFloat) -> CGFloat { 5 * unit }

    var body: some View {
        let points = CGFloat(span.upper - span.lower) * width
        if points >= Self.minimumSpan(unit: unit) {
            Rectangle()
                .fill(LinearGradient(stops: Self.stops(span: span, fillEdge: fillEdge,
                                                       intensity: intensity, accent: accent),
                                     startPoint: .leading, endPoint: .trailing))
                .overlay { overlay() }
                // The comet above is ADDITIVE, and additive light needs a defined backdrop.
                // Without this group it would blend against whatever the window happens to have
                // behind the bar — which is the movie, so the comet's brightness would depend
                // on the frame under it. Grouping pins it to the band.
                .compositingGroup()
                .frame(width: points, height: height)
                // Two clips, and they are different shapes on purpose: the band's own rect
                // keeps the overlay inside the span and butts the band flush against the
                // played fill (a capsule here would leave crescent gaps at the join), while
                // the bar's capsule below rounds it only where the TRACK actually ends.
                .clipped()
                .offset(x: CGFloat(span.lower) * width)
                .frame(width: width, height: height, alignment: .leading)
                .clipShape(Capsule())
        }
    }

    static func stops(span: SeekDelta, fillEdge: Double, intensity: Double,
                      accent: Color = .white) -> [Gradient.Stop] {
        let split = splitLocation(span: span, fillEdge: fillEdge)
        let ink = Color.playerInk.opacity(0.44 * intensity)
        let lift = accent.opacity(0.30 * intensity)
        // Duplicated locations = a hard edge exactly on the fill's own edge, which is where
        // the eye already sees one. A split of 0 or 1 collapses to a single flat tint.
        return [
            .init(color: ink, location: 0),
            .init(color: ink, location: split),
            .init(color: lift, location: split),
            .init(color: lift, location: 1),
        ]
    }

    /// Where the fill's edge falls inside the band, as the band's own 0...1 coordinate.
    static func splitLocation(span: SeekDelta, fillEdge: Double) -> Double {
        let width = span.upper - span.lower
        guard width > 0 else { return fillEdge >= span.upper ? 1 : 0 }
        return ((fillEdge - span.lower) / width).unitClamped
    }
}

extension ScrubSpanBand where Overlay == EmptyView {
    init(span: SeekDelta, fillEdge: Double, width: CGFloat, height: CGFloat,
         unit: CGFloat, intensity: Double = 1, accent: Color = .white) {
        self.init(span: span, fillEdge: fillEdge, width: width, height: height,
                  unit: unit, intensity: intensity, accent: accent) { EmptyView() }
    }
}

/// The travelling highlight over a scrub's delta segment, alive from the commit until the
/// engine lands on the target (`PlayerViewModel.seekSpan`, i.e. exactly the `SeekFlight`
/// window). It says two things the still bar can't: the jump is still in flight, and which
/// way it went.
///
/// Its comet is the concrete indicator's motion TRAIL — the dot leaves A on the same beat
/// and crosses faster (`ScrubTravel.seconds` vs `sweepSeconds`), so the sweep is always
/// behind it. Once the dot has landed and the engine still hasn't, the sweep keeps looping
/// on its own as the "still going" signal.
///
/// Never mounts or unmounts with the seek: it draws nothing when idle and owns its own
/// fade, so the bar's ZStack (whose transactions the handle and fill also ride) never has to
/// animate a structural change to make this appear.
struct ScrubDeltaPulse: View {
    /// See `EnvironmentValues.seekPulsePreview`.
    enum PreviewState: Equatable {
        /// Freeze the comet at this 0...1 sweep phase.
        case sweeping(phase: Double)
        /// Draw the Reduce Motion form: the tint band, no comet.
        case reducedMotion
        /// Mid-drag: the virtual ghost fully up beside the concrete indicator.
        case dragging
        /// Mid-travel: the concrete indicator `progress` of the way from A to B with the
        /// ghost part-dissolved, and the comet frozen at `phase` behind it.
        case traveling(progress: Double, phase: Double)
    }

    /// One glint traversal of the delta, end to end — a fixed DURATION, not a fixed speed, so
    /// the sweep always reads as one traversal of *this* jump however wide it is. Slow enough
    /// to read as deliberate travel rather than a strobe, quick enough that a two-second remote
    /// seek shows two passes.
    static let sweepSeconds: TimeInterval = 0.95
    /// How long the seek must stay in flight before the pulse arms: an AVKit in-buffer seek
    /// lands well inside this, so a local scrub never flashes a frame of pulse. It does not try
    /// to out-wait VLC, whose poll only reports an observed clock every 500ms — a pulse that
    /// arms and immediately fades reads as one soft breath, and pushing the delay past half a
    /// second to suppress it would cost the real reload seeks their first pass.
    /// The concrete indicator's travel is NOT gated on this: a short seek still gets its
    /// glide, it just gets no comet — which is the whole point of the delay.
    static let armDelay: Duration = .milliseconds(220)
    /// The fade in and out. Also the grace the fade-out gets before the last delta is dropped.
    static let fadeSeconds: TimeInterval = 0.22

    /// The live flight, or nil once the engine has landed. Nil doesn't unmount anything — it
    /// starts the fade-out, and `shown` keeps drawing the last span until that finishes.
    let flight: SeekSpan?
    /// The played fill's leading edge right now — which during the travel is the moving
    /// concrete indicator, not the destination.
    let fillEdge: Double
    /// The track's full span in points; the 0...1 fractions resolve against it.
    let width: CGFloat
    let height: CGFloat
    /// `PlayerMetrics.u` — the phone/tv scale the glint's minimum width rides.
    let unit: CGFloat
    /// The seek is provisional until it lands, so all of it — band, comet, breath — is painted
    /// in the accent. `.white` is the monochrome bar.
    var accent: Color = .white

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.seekPulsePreview) private var preview

    /// What's currently drawn. Trails `flight` on both edges: by `armDelay` going up, by the
    /// fade coming down.
    @State private var shown: SeekSpan?
    @State private var visible = false
    /// Phase anchor. Re-stamped whenever a new FLIGHT arms, so a re-scrub's sweep starts at the
    /// leading edge of its own span instead of picking up the old one's phase mid-segment.
    @State private var sweepStart = Date.now

    var body: some View {
        ZStack(alignment: .leading) {
            if let drawn { segment(drawn) }
        }
        .frame(width: width, height: height, alignment: .leading)
        .opacity(preview == nil ? (visible ? 1 : 0) : 1)
        .animation(.easeInOut(duration: Self.fadeSeconds), value: visible)
        .allowsHitTesting(false)
        .task(id: flight?.id) { await follow(flight) }
    }

    /// A pinned preview draws straight off the input: the state machine below runs in a
    /// `.task`, which a preview's single render frame may never reach.
    ///
    /// While the armed flight is still the live one it draws the LIVE fractions rather than the
    /// armed copy: a duration republish mid-hold moves them, and the span is a pure render
    /// input. `shown` only outlives the flight for the length of the fade-out.
    private var drawn: SeekDelta? {
        guard preview == nil else { return flight?.delta }
        guard let shown else { return nil }
        return flight?.id == shown.id ? flight?.delta : shown.delta
    }

    private func follow(_ flight: SeekSpan?) async {
        guard preview == nil else { return }
        guard let flight else {
            visible = false
            try? await Task.sleep(for: .seconds(Self.fadeSeconds))
            guard !Task.isCancelled else { return }
            shown = nil
            return
        }
        // A COLD arm waits out `armDelay` — a seek that lands inside it never draws at all.
        // A re-scrub while the pulse is already up swaps to the new span immediately: the
        // delay exists to suppress flashes, and there is nothing to suppress once the user
        // is already watching a pulse. The direction flip IS the feedback for the re-scrub.
        if shown == nil {
            try? await Task.sleep(for: Self.armDelay)
            guard !Task.isCancelled else { return }
        }
        sweepStart = .now
        shown = flight
        visible = true
    }

    private func segment(_ delta: SeekDelta) -> some View {
        ScrubSpanBand(span: delta, fillEdge: fillEdge, width: width,
                      height: height, unit: unit, accent: accent) {
            glintLayer(delta, span: CGFloat(delta.upper - delta.lower) * width)
        }
    }

    /// Reduce Motion draws no comet and no breath at all. The tint band alone is the static
    /// differentiated fill the guideline asks for — it still carries "this stretch is in
    /// flight", just without the travel that says which way.
    @ViewBuilder
    private func glintLayer(_ delta: SeekDelta, span: CGFloat) -> some View {
        switch preview {
        case .sweeping(let phase), .traveling(_, let phase):
            sweep(delta, span: span, phase: phase)
        case .reducedMotion, .dragging:
            EmptyView()
        case nil where !reduceMotion:
            TimelineView(.animation) { context in
                sweep(delta, span: span,
                      phase: Self.phase(at: context.date, since: sweepStart))
            }
        case nil:
            EmptyView()
        }
    }

    /// The two things that ride the sweep phase: the whole span breathing under the comet, and
    /// the comet itself. Both additive — light laid ON the band, not paint mixed into it, which
    /// is what keeps them legible over the dark ink half and the bright fill alike.
    private func sweep(_ delta: SeekDelta, span: CGFloat, phase: Double) -> some View {
        ZStack {
            accent
                .opacity(Self.breath(atPhase: phase))
                .blendMode(.plusLighter)
            glint(delta, span: span, phase: phase)
        }
    }

    /// One breath per comet sweep, so the two readings of "still landing" — the pass and the
    /// swell — are the same clock rather than two rhythms beating against each other. Shallow
    /// on purpose: this plays under the scrub bubble and must never pull the eye off it.
    static func breath(atPhase phase: Double) -> Double {
        0.05 + 0.05 * (1 - cos(2 * .pi * phase)) / 2
    }

    private func glint(_ delta: SeekDelta, span: CGFloat, phase: Double) -> some View {
        let glintWidth = max(34 * unit, span * 0.3)
        // Travel far enough that the comet clears the segment entirely at both ends — which is
        // what lets the sweep restart at phase 0 with no visible snap: at either extreme it's
        // fully outside the `.clipped()` rect, so there is nothing on screen to jump.
        let travel = (span + glintWidth) / 2
        let x = delta.isForward ? -travel + 2 * travel * phase : travel - 2 * travel * phase
        return LinearGradient(
            stops: cometStops(delta),
            startPoint: delta.isForward ? .leading : .trailing,
            endPoint: delta.isForward ? .trailing : .leading
        )
        .frame(width: glintWidth)
        .offset(x: x)
        // Additive, so the comet is a light passing over the span rather than a paler paint
        // stroke across it — the difference between a trail and a smear on the ink half.
        .blendMode(.plusLighter)
    }

    /// Asymmetric on purpose: a long tail into a bright head near the far end, so the shape
    /// itself points the way it's going rather than relying on the motion alone.
    private func cometStops(_ delta: SeekDelta) -> [Gradient.Stop] {
        let peak = delta.isForward ? 0.62 : 0.45
        return [
            .init(color: accent.opacity(0), location: 0),
            .init(color: accent.opacity(peak * 0.28), location: 0.52),
            .init(color: accent.opacity(peak), location: 0.88),
            .init(color: accent.opacity(0), location: 1),
        ]
    }

    /// Wall-clock → 0..<1 sweep phase. Pure so the ramp (and its wrap) is testable without a
    /// running timeline.
    static func phase(at date: Date, since start: Date) -> Double {
        let turns = date.timeIntervalSince(start) / sweepSeconds
        return turns - turns.rounded(.down)
    }
}

/// The concrete indicator's arrival flare: a soft radial pool of the accent that swells under the
/// head as it touches down at B and is gone a beat later. Additive (`plusLighter`) because it is
/// LIGHT — a normal-blended halo over video reads as a smudge, and over the bright played fill it
/// reads as dirt. Zero opacity draws nothing, which is its resting state, and the resting state is
/// the whole film: the solid handle is flat white with no glow of its own, and this is the one
/// moment it is allowed any.
struct ScrubArrivalBloom: View {
    let accent: Color
    let diameter: CGFloat
    let opacity: Double

    var body: some View {
        Circle()
            .fill(RadialGradient(
                stops: [
                    .init(color: accent.opacity(0.85), location: 0),
                    .init(color: accent.opacity(0.35), location: 0.45),
                    .init(color: accent.opacity(0), location: 1),
                ],
                center: .center, startRadius: 0, endRadius: diameter / 2
            ))
            .frame(width: diameter, height: diameter)
            .blendMode(.plusLighter)
            .opacity(opacity)
            .allowsHitTesting(false)
    }
}
