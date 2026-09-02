import SwiftUI

/// The single layered progress bar for every platform and state — replaces the iOS
/// `Slider`, the tvOS focusable bar, and the old `ScrubBar`. Monochrome white over the
/// video scrim, panel-less. The track runs the full row width with the time labels
/// ABOVE its two ends (the tvOS system player's title-above-scrubber anatomy); during
/// `.scrub` the labels fade out — the floating bubble carries the time, and near either
/// end it would collide with them. Visual only: `played` is a 0...1 fraction the caller
/// supplies (live playback, a drag preview, or the reducer's scrub head). When
/// `onScrubChanged`/`onScrubEnded` are set (iOS), a drag anywhere on the bar scrubs
/// RELATIVE to the current position — grabbing the bar is grabbing the handle, from
/// wherever the finger lands; a plain tap is inert (no jump-to-tap seeking). tvOS
/// leaves the handlers nil and drives seeking via the remote, so no drag gesture is
/// attached there.
struct PlayerProgressBar: View {
    enum Mode: Equatable { case normal, focused, scrub }

    /// The playhead's form while scrubbing — and with it the form of the virtual indicator
    /// that ghosts it, since a ghost is only legible as a ghost of something. Every scrub
    /// surface uses the tall pill (`.line`): the iOS drag and the mini bar (`PlayerScrubBar`,
    /// the read-only dome-riding one) both morph into it, which is the grammar the bar shipped
    /// with. `.dot` keeps the bead through the scrub, and is what the diagnostic previews use
    /// to show the two side by side. Only `.scrub` reads this at all: `.normal` and `.focused`
    /// are the dot everywhere.
    enum Playhead: Equatable { case dot, line }

    let metrics: PlayerMetrics
    var mode: Mode = .normal
    var playhead: Playhead = .dot
    /// No known runtime (incomplete media playing with an `.indefinite` duration): the timeline
    /// isn't scrubbable, so suppress the draggable handle and the played fill — the bar becomes a
    /// dim track carrying only the live elapsed label. The caller also blanks `remaining` and the
    /// scrub handlers. Derived once from `vm.hasKnownDuration` in `init(vm:)`.
    var indeterminate: Bool = false
    let played: Double
    /// The honest playback position while a scrub previews somewhere ELSE on the bar — the
    /// CONCRETE indicator. Nil is the single-indicator bar, where `played` is both the fill
    /// and the handle. Non-nil splits them: the fill and the solid handle stay here, on where
    /// the (scrub-paused) video actually is, and `played` becomes the VIRTUAL position the
    /// gesture is aiming at — the ghost handle, the bubble, and the time readout.
    var concrete: Double? = nil
    /// 0...1 fraction the buffer extends to — the spec's middle layer (track
    /// `white 0.20` → buffered `white 0.36` → played `#fff`). Seeks inside it are
    /// instant (no server round-trip), so it doubles as the scrub affordance.
    /// Nil hides the layer (VLC path, or nothing buffered around the playhead).
    var buffered: Double? = nil
    /// The in-flight seek (`PlayerViewModel.seekSpan`) — the A→B stretch `ScrubDeltaPulse`
    /// sweeps and the concrete indicator crosses while the engine is still landing, plus the
    /// flight id every one of those animations is keyed on. Nil at rest, and nil while a
    /// gesture is still previewing: nothing is in flight until a commit.
    var flight: SeekSpan? = nil
    let elapsed: String
    let remaining: String
    /// Seconds behind `elapsed`/`remaining` (and the bubble). They drive the
    /// `.numericText` content transitions, so an animated scrub change rolls the
    /// digits instead of cross-fading the whole label; unanimated updates (live
    /// playback ticks) run no transition either way.
    let elapsedSeconds: Double
    let remainingSeconds: Double
    /// Chapter start fractions (0...1); ticks render in every mode so the bar keeps
    /// its chapter landmarks across the HUD↔scrub switch instead of popping them in.
    var chapters: [Double] = []
    /// Big floating time + chapter label above the handle; `.scrub` only.
    var bubbleTime: String? = nil
    var bubbleChapter: String? = nil
    /// iOS drag handlers (nil on tvOS).
    var onScrubChanged: ((Double) -> Void)? = nil
    var onScrubEnded: ((Double) -> Void)? = nil
    /// Drives the floating bubble's `.numericText` digit roll on its OWN transaction,
    /// decoupled from the scrub head's position animation — so tvOS analog scrub can pin
    /// the head 1:1 (accurate at 24fps, display == the value Select commits) while the
    /// timestamp still rolls. The position-free half of the "aliveness" that the single
    /// position spring used to bundle together with the accuracy-killing glide. Nil =
    /// ambient behavior (iOS drag, the full-HUD scrubber), so those paths are untouched.
    var scrubDigitRoll: Animation? = nil
    /// Whether this instance reports itself to `PlayerPullToDismiss`'s no-pull exclusion zone
    /// (iOS only — see `pullToDismissExclusion` below). True for the interactive HUD bar, the
    /// only one a finger can actually grab. `PlayerScrubBar`'s read-only, `allowsHitTesting(false)`
    /// dome-riding bar sets this false: nothing can start a drag there, so a zone was always inert,
    /// and that bar rides `PlayerControlsView.seekScrubBar`'s `TimelineView(.animation)` — reporting
    /// from inside it re-declared the preference on every seek-flash tick and tripped SwiftUI's
    /// "PullExclusionZonesKey tried to update multiple times per frame".
    var reportsPullExclusion: Bool = true

    /// The hue every PROVISIONAL element of the bar is painted in — the ghost handle, the span
    /// band, the comet and its breath, the arrival bloom. Everything that carries INFORMATION
    /// stays white: the played fill, the solid handle, the time labels, the chapter ticks, and
    /// the scrub bubble's timestamp and chapter caption. A fact shouldn't change colour with the
    /// poster, and the bubble is the most load-bearing fact on the bar — it floats over live
    /// video with nothing but a drop shadow behind it, and `ArtworkAccent`'s band is an HSB one
    /// (`brightness >= 0.70` is `max(r,g,b)`, not luminance), so a saturated blue that passes it
    /// can still read as dark ink over a bright frame. White cannot fail.
    @Environment(\.scrubAccent) private var accent

    private var trackH: CGFloat { metrics.trackHeight }
    private var labelSize: CGFloat { metrics.timeLabelSize }
    /// Reserve the tallest handle of ANY mode, not just the current one, so the row —
    /// and with it the track's vertical center — is identical across normal/focused/
    /// scrub and the HUD↔scrub switch can't shift the bar.
    private var rowHeight: CGFloat {
        max(trackH + 22 * metrics.u, metrics.handleDiameterFocused + 6 * metrics.u)
    }

    /// The scrub handle's tall-pill form: `.scrub` on a line-grammar surface, where the
    /// playhead is a vertical sliver rather than a bead. Three geometry properties asked the
    /// same question; this is the answer, once.
    private var isScrubLine: Bool { mode == .scrub && playhead == .line }

    var body: some View {
        VStack(spacing: 6 * metrics.u) {
            // Labels above the track ends. Opacity-hidden in `.scrub` (never a
            // structural `if`): the row's height is part of the bar's reserved
            // geometry, and unmounting it would shift the track on the HUD↔scrub
            // switch — the exact jump `rowHeight` exists to prevent.
            HStack(alignment: .firstTextBaseline, spacing: metrics.progressRowGap) {
                Text(elapsed)
                    .font(.system(size: labelSize, weight: .semibold).monospacedDigit())
                    .contentTransition(.numericText(value: elapsedSeconds))
                    .foregroundStyle(.white)
                Spacer(minLength: 0)
                Text(remaining)
                    .font(.system(size: labelSize, weight: .semibold).monospacedDigit())
                    .contentTransition(.numericText(value: remainingSeconds))
                    .foregroundStyle(.white.opacity(0.62))
            }
            .opacity(mode == .scrub ? 0 : 1)

            GeometryReader { geo in
                let w = geo.size.width
                let p = played.unitClamped
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.20)).frame(height: trackH)
                    if let buffered {
                        Capsule().fill(.white.opacity(0.36))
                            .frame(width: w * buffered.unitClamped, height: trackH)
                    }
                    // No played fill / handle without a known runtime — there's no fraction to
                    // show and nothing to grab. The dim track + live elapsed label carry it.
                    // NOTE: when the VLC read-rate estimate lands (~3s into incomplete media),
                    // `indeterminate` flips false and these elements insert with no transition — a
                    // one-time pop, accepted (a crossfade here fights the normal↔scrub morph and the
                    // reserved-geometry invariant, and the estimate makes the flip a once-per-item event).
                    if !indeterminate {
                        ScrubIndicators(concrete: concrete?.unitClamped,
                                        flight: flight,
                                        width: w) { indicators in
                            // The concrete indicator's drawn x. At rest the travel offset is
                            // exactly 0, so this collapses to `w * played` and the caller's
                            // own position animation still owns the playhead.
                            let cx = min(max(w * (concrete ?? played).unitClamped
                                             + indicators.travelOffset, 0), w)
                            let cf = w > 0 ? cx / w : 0

                            Capsule().fill(.white).frame(width: cx, height: trackH)

                            // The gap the gesture has opened up, differentiated but kept well
                            // under the pulse's strength — the scrub bubble sits directly over
                            // this stretch and must stay the loudest thing on the bar.
                            if let concrete {
                                ScrubSpanBand(span: SeekDelta(from: concrete.unitClamped, to: p),
                                              fillEdge: cf, width: w, height: trackH,
                                              unit: metrics.u, intensity: 0.6)
                            }

                            ScrubDeltaPulse(flight: flight, fillEdge: cf, width: w,
                                            height: trackH, unit: metrics.u)

                            ForEach(chapters, id: \.self) { c in
                                Rectangle()
                                    .fill(c <= cf ? Color.playerInk.opacity(0.5) : .white.opacity(0.5))
                                    .frame(width: metrics.chapterTickWidth, height: trackH)
                                    .offset(x: w * c.unitClamped - metrics.chapterTickWidth / 2)
                            }

                            // Drawn at the virtual position always — invisible (opacity 0) on
                            // the single-indicator bar, so nothing structural changes when a
                            // gesture summons it.
                            handle(ghost: true)
                                .opacity(indicators.ghostOpacity)
                                // The dissolve is the crossing's second beat and runs on its
                                // own curve, so it can't ride the travel's transaction. A nil
                                // animation is the ghost APPEARING (a gesture summoning it, and
                                // Reduce Motion's instant hand-back), which must not fade in.
                                .animation(indicators.ghostFade, value: indicators.ghostOpacity)
                                .offset(x: w * p - handleWidth / 2)

                            handle(ghost: false)
                                // Behind the head, so the flare reads as the bead landing IN a
                                // pool of its own light rather than as a second disc over it.
                                .background {
                                    // Off the handle's LONG side, so the line grammar's flare is
                                    // a pool around a tall sliver rather than a 7pt-wide dab.
                                    ScrubArrivalBloom(
                                        diameter: max(handleWidth, handleHeight) * 1.9,
                                        opacity: indicators.bloom)
                                }
                                // The bloom is ADDITIVE, and additive light needs a defined
                                // backdrop — the rule `ScrubSpanBand` states for the comet, and
                                // the bloom is the same construct. Without this group its blend
                                // would reach the MOVIE: invisible over a bright frame, glaring
                                // over a black one, i.e. the flare's strength decided by whatever
                                // shot the seek happened to land on. Grouping pins it to the
                                // handle it belongs to, so it renders the same over any frame.
                                .compositingGroup()
                                .offset(x: cx - handleWidth / 2)
                        }
                    }

                    if !indeterminate, mode == .scrub, let bubbleTime {
                        bubble(bubbleTime)
                            .modifier(ClampedBubblePosition(
                                barWidth: w, playheadX: w * p,
                                y: -(bubbleHeight / 2 + 14 * metrics.u)))
                    }
                }
                .frame(height: rowHeight, alignment: .center)
                #if os(tvOS)
                // No drag gesture on tvOS (the bar lives in a focusable Button) —
                // an extended hit rect would grow the Button's focus geometry.
                .contentShape(Rectangle())
                #else
                // Hit area only — visuals unchanged. The bar row is ~22-32pt;
                // the extension reaches the HIG 44pt touch floor and covers the
                // (non-interactive, scrub-faded) time labels above, so a grab
                // aimed slightly high still starts the scrub. TOP-only by
                // construction: the chips sit directly below with almost no
                // clearance (phone: the rows already touch).
                .contentShape(TopExtendedRectangle(
                    topExtension: max(28 * metrics.u, 44 - rowHeight)))
                // Same reach as the hit shape above: a drag that starts where a
                // scrub CAN start must never become a pull-to-dismiss.
                .pullToDismissExclusion(
                    extendingTop: max(28 * metrics.u, 44 - rowHeight),
                    active: reportsPullExclusion
                )
                #endif
                .modifier(ScrubGesture(width: w, played: p,
                                       onChanged: onScrubChanged, onEnded: onScrubEnded))
            }
            .frame(height: rowHeight)
        }
    }

    private var handleWidth: CGFloat {
        switch mode {
        case .normal: metrics.handleDiameter
        case .focused: metrics.handleDiameterFocused
        case .scrub: isScrubLine ? metrics.scrubHandleWidth : metrics.handleDiameter
        }
    }

    /// ONE view identity across all three modes — width/height/radius retarget on a
    /// mode flip instead of crossfading two handle views. The structural `switch`
    /// this replaces ghosted during the normal↔scrub transition: the outgoing dot
    /// froze at its removal-time offset while the incoming pill tracked the finger,
    /// reading as a misaligned dot beside the scrub line (device-caught).
    ///
    /// `ghost` is the same silhouette hollowed out: a translucent fill under a bright outline,
    /// so the virtual indicator reads as an unfilled copy of the concrete one rather than as a
    /// second, weaker playhead. Both are FLAT — one tint each, no gradient, no specular, no
    /// bevel. A material here reads as a button, and the bar is a bar.
    ///
    /// Colour splits the pair: the hollow form is provisional, so it wears the artwork accent
    /// and the soft light that goes with it; the solid one is the honest position, so it stays
    /// plain white and never glows.
    private func handle(ghost: Bool) -> some View {
        RoundedRectangle(cornerRadius: handleCornerRadius, style: .continuous)
            .fill(ghost ? accent.opacity(0.22) : .white)
            .frame(width: handleWidth, height: handleHeight)
            .overlay {
                RoundedRectangle(cornerRadius: handleCornerRadius, style: .continuous)
                    .strokeBorder(accent.opacity(0.9), lineWidth: 2 * metrics.u)
                    .opacity(ghost ? 1 : 0)
            }
            .modifier(ScrubGhostGlow(color: accent, radius: ghost ? 7 * metrics.u : 0))
            .overlay {
                Circle().strokeBorder(.white.opacity(0.55), lineWidth: 3 * metrics.u)
                    .padding(-3 * metrics.u)
                    .opacity(!ghost && mode == .focused ? 1 : 0)
            }
            .shadow(color: .black.opacity(ghost ? 0.35 : 0.5),
                    radius: (mode == .scrub ? 5 : 2) * metrics.u, y: 1)
    }

    private var handleHeight: CGFloat {
        switch mode {
        case .normal: metrics.handleDiameter
        case .focused: metrics.handleDiameterFocused
        case .scrub: isScrubLine ? trackH + 22 * metrics.u : metrics.handleDiameter
        }
    }

    private var handleCornerRadius: CGFloat {
        isScrubLine ? 5 * metrics.u : handleWidth / 2
    }

    /// Approximate so the bubble floats just above the handle; `.position` only needs the
    /// view's centre, and exact height isn't load-bearing here.
    private var bubbleHeight: CGFloat {
        metrics.scrubBubbleSize + (bubbleChapter == nil ? 0 : metrics.scrubChapterSize + 10 * metrics.u)
    }

    /// No `.fixedSize()` on the stack: `.position` forwards the bar's width as the
    /// proposal (render-proven — a `frame(maxWidth:)` here filled to it), so the chapter
    /// title truncates with an ellipsis at the bar's span instead of driving the whole
    /// (`ClampedBubblePosition`-measured) bubble wider than the bar, where the clamp's
    /// centring fallback would overhang BOTH screen edges (device-caught on iPad). The
    /// stack still sizes to content, so the clamp's edge-parking keeps working. The time
    /// keeps its own `.fixedSize()` — a timestamp must never truncate or wrap.
    private func bubble(_ time: String) -> some View {
        VStack(spacing: 10 * metrics.u) {
            Text(time)
                .font(.system(size: metrics.scrubBubbleSize, weight: .bold).monospacedDigit())
                .contentTransition(.numericText(value: elapsedSeconds))
                .modifier(OptionalDigitRoll(animation: scrubDigitRoll, value: elapsedSeconds))
                // White, not the accent: the bubble is the one piece of CONTENT the scrub HUD
                // exists to show, and it sits over live video behind nothing but a shadow. See
                // `accent` above for why the artwork band is no contrast floor.
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.6), radius: 20 * metrics.u, y: 2)
                .fixedSize()
            if let bubbleChapter {
                Text(bubbleChapter)
                    .font(.system(size: metrics.scrubChapterSize, weight: .medium))
                    .foregroundStyle(.white.opacity(0.74))
                    .lineLimit(1)
            }
        }
    }
}

/// What the bar draws for the concrete/virtual pair this frame. One value rather than three
/// anonymous `Double`s, because the ghost's fade needs its own curve: the crossing and the
/// dissolve are two beats, and the second one cannot ride the first one's transaction.
private struct ScrubIndicatorState {
    /// The concrete indicator's displacement from where the bar's own inputs place it. Exactly
    /// 0 at rest, which is what keeps the resting bar a pure function of its inputs.
    let travelOffset: CGFloat
    let ghostOpacity: Double
    /// The curve the ghost's opacity change runs on, or nil for an instant one.
    let ghostFade: Animation?
    let bloom: Double
}

/// Owns the only two things in the concrete/virtual model that need MEMORY: the concrete
/// indicator's travel to the virtual one when the seek LANDS, and the arrival flare that lights
/// as it touches down. It draws nothing — it hands the bar a `ScrubIndicatorState` and leaves
/// every point of geometry where it already lived.
///
/// Both are "which flight have I launched", an integer compare against `SeekFlight.id`, and
/// that shape is load-bearing three times over. The first frame of a commit is already correct
/// (a POSITION mirror updated from `onChange` would flash the destination before jumping back
/// to the origin — `retained` below is such a mirror, but it never sources a position while the
/// flight is live, so lagging a frame costs it nothing). The resting values are exactly 0 and 0,
/// so the callers' own position animations (the mini bar's click-seek spring, the tvOS analog
/// 1:1 pin) keep owning the playhead. And a duration republish mid-flight — a re-anchor's
/// `applyDuration` moving every fraction by a frame's worth — cannot restart a crossing, because
/// no animation here is keyed on a fraction.
///
/// The crossing is earned by the LANDING, which is the beat the model drops the flight on — so
/// this keeps its own copy of the span to cross (`retained`), because by then the model has
/// nothing left to hand over.
///
/// There is no state for "the gesture ended but the commit hasn't arrived": the view model
/// publishes `.previewing` → `.committed` on the beat the finger lifts, so there is no gap to
/// sleep through and nothing to remember across it.
///
/// It's a separate view because `PlayerProgressBar` must stay a pure value type: a private
/// `@State` on the struct would make its memberwise init file-private, and the
/// `init(vm:)` convenience in `PlayerScrubBar.swift` is built on that init.
private struct ScrubIndicators<Content: View>: View {
    /// The concrete indicator's fraction while a gesture previews a seek; nil on the
    /// single-indicator bar. Already clamped.
    let concrete: Double?
    /// The committed jump and its identity, or nil when nothing is in flight.
    let flight: SeekSpan?
    /// The track's full span in points.
    let width: CGFloat
    @ViewBuilder let content: (ScrubIndicatorState) -> Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.seekPulsePreview) private var preview

    /// The flight whose crossing has been LAUNCHED — which is when that flight ENDS. Until
    /// then the concrete indicator is held back at A; flipping this inside `withAnimation` is
    /// what makes the crossing a crossing.
    @State private var launched: UInt64?
    /// The last flight, kept past its end, because the crossing is earned when the seek lands
    /// and by then the model has nothing left to hand over. Refreshed on every change of the
    /// live span, not just on a new id — a duration republish moves the fractions.
    @State private var retained: SeekSpan?
    /// The flight whose arrival flare is lit. An id rather than a flag so a cancelled sleep can
    /// never put out a flare that belongs to a newer crossing.
    @State private var blooming: UInt64?

    var body: some View {
        ZStack(alignment: .leading) {
            content(ScrubIndicatorState(travelOffset: travelOffset, ghostOpacity: ghostOpacity,
                                        ghostFade: ghostFade, bloom: bloomOpacity))
        }
        .onChange(of: flight, initial: true) { _, flight in if let flight { retained = flight } }
        .task(id: flight?.id) { await land() }
    }

    /// Holds the concrete indicator (and the ghost it is aiming at) at A for the whole flight,
    /// then hands it to the destination in one animated step the moment the seek lands, and lights
    /// and lets go of the arrival flare. Everything before that step is derived, so the frame the
    /// landing arrives on is already drawn at A.
    private func land() async {
        guard preview == nil else { return }
        // A flare belongs to the crossing that lit it. Put out anything still burning before
        // this flight decides what it is, so two landings can't overlap into one long glow.
        if blooming != nil { withAnimation(ScrubTravel.bloomFall) { blooming = nil } }
        // In flight there is nothing to launch: the picture is still at A (or still fetching B),
        // and so is the indicator.
        guard flight == nil, let retained, launched != retained.id else { return }
        // One turn, so the frame holding the indicator at A is drawn and the release has
        // something to animate FROM.
        await Task.yield()
        guard !Task.isCancelled else { return }

        // Reduce Motion gets the positional change with no glide and no flare: there is no
        // travel to arrive from, so a light here would be a light with no motion to explain it.
        guard !reduceMotion else { launched = retained.id; return }
        withAnimation(ScrubTravel.curve) { launched = retained.id }
        withAnimation(ScrubTravel.bloomRise) { blooming = retained.id }
        try? await Task.sleep(for: .seconds(ScrubTravel.seconds))
        // Not `Task.isCancelled`: a cancelled sleep still has to hand the flare back, and the
        // id is what keeps this from putting out a NEWER crossing's flare instead of its own.
        guard blooming == retained.id else { return }
        withAnimation(ScrubTravel.bloomFall) { blooming = nil }
    }

    private var parked: SeekSpan? {
        ScrubTravel.parked(flight: flight, retained: retained, launched: launched)
    }

    /// Reduce Motion holds the indicator at A exactly like everything else — the picture is
    /// there, and the ghost is dropped so the parked head is the only marker — and then jumps
    /// it to B on the landing instead of gliding. The static tint band still marks the span.
    ///
    /// A re-scrub landing mid-crossing abandons it rather than continuing: a live gesture
    /// blanks the flight by definition (nothing is in flight until it commits). It abandons AT
    /// A — the gesture's `concrete` is the unlanded flight's own origin, which is the point the
    /// crossing had left — so the indicator drops back to the position the picture is still
    /// showing rather than stranding part-way to a target it never reached. It takes lifting
    /// and re-pressing inside half a second to see it at all.
    private var travelOffset: CGFloat {
        if case .traveling(let progress, _) = preview, let flight {
            return ScrubTravel.offset(flight.delta, width: width, progress: progress)
        }
        guard preview == nil, concrete == nil, let parked else { return 0 }
        return ScrubTravel.parkOffset(parked.delta, width: width)
    }

    /// The ghost is the DESTINATION marker: fully up while a gesture owns the bar, up for the
    /// whole flight (the target is only a promise until the seek lands), held through the first
    /// half of the crossing the landing launches, gone at touchdown.
    ///
    /// Reduce Motion keeps the gesture's ghost — a static marker of where the finger is aiming
    /// carries information, and losing it would leave the split with only one indicator — but
    /// drops the post-commit one: with no crossing to absorb it, a second head standing at B
    /// would just wink out when the seek lands, and the static tint band already says which
    /// stretch is in flight.
    private var ghostOpacity: Double {
        switch preview {
        case .dragging: return 1
        case .traveling(let progress, _): return ScrubTravel.ghostOpacity(atTravel: progress)
        case .sweeping, .reducedMotion: return 0
        case nil:
            if concrete != nil { return 1 }
            guard !reduceMotion else { return 0 }
            return parked == nil ? 0 : 1
        }
    }

    private var ghostFade: Animation? {
        guard preview == nil, !reduceMotion, ghostOpacity == 0 else { return nil }
        return ScrubTravel.dissolve
    }

    /// The flare's strength. A pinned preview samples the same ramp the live rise animates, so
    /// the render and the device agree on what "mid-crossing" looks like; the live path can't
    /// use the ramp directly because it has no per-frame progress to feed it.
    private var bloomOpacity: Double {
        switch preview {
        case .traveling(let progress, _): return ScrubTravel.bloom(atTravel: progress)
        case .dragging, .sweeping, .reducedMotion: return 0
        case nil: return blooming == nil ? 0 : 1
        }
    }
}

/// Positions the floating bubble on the playhead, clamped so it never leaves the bar's
/// span: near either end the bubble parks at the edge while the handle keeps travelling
/// (the system players' behavior). Unclamped, the playhead-centred bubble ran past the
/// screen on portrait iPhone — the 26pt `phonePadX` inset can't absorb half a time
/// label. A bubble wider than the bar itself (degenerate multitask window) centres.
/// Owns the measured width so `PlayerProgressBar` keeps its value-only memberwise init
/// (a private `@State` on the struct would make that init private to its file).
private struct ClampedBubblePosition: ViewModifier {
    let barWidth: CGFloat
    let playheadX: CGFloat
    let y: CGFloat
    @State private var width: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            .position(x: barWidth > width
                          ? min(max(playheadX, width / 2), barWidth - width / 2)
                          : barWidth / 2,
                      y: y)
    }
}

/// The scrub bar's hit region: the row's rect grown UPWARD only. Out-of-bounds
/// hits are delivered because no ancestor in the bar's chain clips — adding a
/// `.clipped()`/`.clipShape` anywhere above the scrubber would silently kill
/// the extra grab zone.
private struct TopExtendedRectangle: Shape {
    var topExtension: CGFloat
    func path(in rect: CGRect) -> Path {
        Path(CGRect(x: rect.minX, y: rect.minY - topExtension,
                    width: rect.width, height: rect.height + topExtension))
    }
}

/// Attaches the iOS drag-to-seek gesture ONLY when a handler is present, so the tvOS
/// path (handlers nil, bar driven by the remote inside a focusable Button) gets no
/// gesture that could fight the focus engine. `DragGesture` is unavailable on tvOS, so
/// the whole gesture path is compiled out there — the remote drives the bar instead.
///
/// The drag is RELATIVE: the displayed fraction is captured at drag start and the
/// finger's translation moves the playhead from there — grabbing any part of the bar
/// is grabbing the handle. (The old absolute `location.x / width` mapping made a bare
/// touch JUMP the playhead to the tap point.) `minimumDistance` keeps plain taps from
/// engaging at all: no jump, no pause, no seek.
private struct ScrubGesture: ViewModifier {
    let width: CGFloat
    /// The bar's currently displayed fraction — the relative drag's anchor.
    let played: Double
    let onChanged: ((Double) -> Void)?
    let onEnded: ((Double) -> Void)?
    @State private var startFraction: Double? = nil
    #if !os(tvOS)
    /// Gesture liveness. `onEnded` only fires when a drag SUCCEEDS — a system steal
    /// (home-indicator swipe under the bar, notification pull) cancels the gesture
    /// with no callback at all, which would strand `startFraction` AND the parent's
    /// whole scrub state (engine paused, chrome collapsed, next grab anchored at the
    /// old drag's start). `@GestureState` is the one thing the system resets even on
    /// cancellation, so its false-flip is the cancel signal.
    @GestureState private var dragActive = false
    /// The last fraction reported to `onChanged` — what a detected cancel commits.
    @State private var lastReported: Double? = nil
    #endif

    func body(content: Content) -> some View {
        #if os(tvOS)
        content
        #else
        if onChanged == nil && onEnded == nil {
            content
        } else {
            content.gesture(
                DragGesture(minimumDistance: 9, coordinateSpace: .local)
                    .updating($dragActive) { _, active, _ in active = true }
                    .onChanged { v in
                        guard width > 0 else { return }
                        let base = startFraction ?? played
                        if startFraction == nil { startFraction = base }
                        let fraction = (base + v.translation.width / width).unitClamped
                        lastReported = fraction
                        onChanged?(fraction)
                    }
                    .onEnded { v in
                        guard width > 0 else { return }
                        let base = startFraction ?? played
                        startFraction = nil
                        lastReported = nil
                        onEnded?((base + v.translation.width / width).unitClamped)
                    }
            )
            // Cancellation path: `dragActive` resets to false with `lastReported`
            // still set only when the system killed the drag without `onEnded`.
            // Route it through the normal end at the last reported fraction so the
            // parent commits/resumes instead of stranding paused. (A normal end
            // clears `lastReported` first, so this never double-fires.)
            .onChange(of: dragActive) { _, active in
                guard !active, let fraction = lastReported else { return }
                startFraction = nil
                lastReported = nil
                onEnded?(fraction)
            }
        }
        #endif
    }
}

/// Applies a content-transition animation ONLY when one is supplied. A nil leaves the
/// ambient behavior untouched (other callers' digit roll), whereas `.animation(nil, value:)`
/// would actively DISABLE it — stopping the bubble's roll on the iOS/full-HUD paths.
private struct OptionalDigitRoll: ViewModifier {
    let animation: Animation?
    let value: Double
    func body(content: Content) -> some View {
        if let animation { content.animation(animation, value: value) }
        else { content }
    }
}

/// The ghost handle's soft outward light, and a genuine no-op at radius 0.
///
/// Structural rather than a `.shadow(color: .clear)`: the glow needs a `compositingGroup` so the
/// fill and its outline cast ONE light instead of two, and that group is an offscreen pass. The
/// concrete handle is on screen for the whole film and never glows — it must not pay for a pass
/// it doesn't use, sixty times a second, on a drag.
private struct ScrubGhostGlow: ViewModifier {
    let color: Color
    let radius: CGFloat

    func body(content: Content) -> some View {
        if radius > 0 {
            content.compositingGroup().shadow(color: color.opacity(0.5), radius: radius)
        } else {
            content
        }
    }
}

/// One diagnostic bar for the concrete/virtual previews below. Defaults are the settled
/// single-indicator bar in the monochrome fallback; each preview row overrides only the part
/// it is exhibiting. The flight id is arbitrary here — a render has no second flight to
/// supersede this one.
private func indicatorPreviewBar(
    played: Double,
    concrete: Double? = nil,
    delta: SeekDelta? = nil,
    mode: PlayerProgressBar.Mode = .normal,
    playhead: PlayerProgressBar.Playhead = .dot,
    bubble: String? = nil
) -> some View {
    PlayerProgressBar(metrics: .tv, mode: mode, playhead: playhead, played: played,
                      concrete: concrete, buffered: 0.81,
                      flight: delta.map { SeekSpan(id: 1, delta: $0) },
                      elapsed: "1:04:18", remaining: "-1:02:42",
                      elapsedSeconds: 3858, remainingSeconds: 3762,
                      chapters: [0.12, 0.41, 0.58, 0.89],
                      bubbleTime: bubble)
}

/// The three accents every state preview is rendered against. Two artwork-plausible hues that
/// the normalizer would actually produce (`ArtworkAccent.normalized` clamps into
/// saturation 0.35–0.75, brightness ≥ 0.70) plus the white fallback a grey poster falls back to
/// — so a render answers "does the hue read" and "is the fallback still the monochrome bar" at
/// the same time. Both sit near the saturated end: that is where most posters now land, and a
/// hue that survives there survives anywhere in the band.
private enum ScrubAccentPreview {
    /// A warm poster's hue — the amber end of the range.
    static let ember = Color(hue: 0.06, saturation: 0.70, brightness: 0.92)
    /// A cool one — the teal/cyan end.
    static let cool = Color(hue: 0.55, saturation: 0.64, brightness: 0.86)
    /// No usable colour in the artwork: the bar is exactly what it was before the accent existed.
    static let fallback = Color.white

    static let all: [(String, Color)] = [("ember", ember), ("cool", cool), ("white", fallback)]
}

// PHASE 1 — the drag. Two indicators: the CONCRETE one (solid, on the paused playback
// position, carrying the played fill) and its VIRTUAL ghost riding the gesture. The gap
// between them carries the soft split band; the bubble belongs to the ghost.
//
// Row 1 — forward drag on the full-HUD bar: solid dot at 0.28, ghost dot at 0.72, band
//   LIFTED (it lies past the fill, on bare track).
// Row 2 — backward drag on the same bar: ghost at 0.28, solid at 0.72, band INKED (it lies
//   inside the fill). The fill must still end at 0.72 — honest to the concrete position.
// Row 3/4 — the same two on the mini bar, where the grammar is the vertical line.
#Preview("scrub indicators — drag (dot bar / line bar)", traits: .fixedLayout(width: 1200, height: 760)) {
    ZStack {
        LinearGradient(colors: [.purple, .black], startPoint: .topLeading, endPoint: .bottomTrailing)
            .ignoresSafeArea()
        VStack(spacing: 70) {
            indicatorPreviewBar(played: 0.72, concrete: 0.28, mode: .scrub, bubble: "1:31:10")
            indicatorPreviewBar(played: 0.28, concrete: 0.72, mode: .scrub, bubble: "0:35:20")
            indicatorPreviewBar(played: 0.72, concrete: 0.28, mode: .scrub,
                                playhead: .line, bubble: "1:31:10")
            indicatorPreviewBar(played: 0.28, concrete: 0.72, mode: .scrub,
                                playhead: .line, bubble: "0:35:20")
        }
        .padding(60)
        .environment(\.seekPulsePreview, .dragging)
    }
    .frame(width: 1200, height: 760)
    .environment(\.colorScheme, .dark)
}

// PHASE 2 — the travel. The gesture is over, so `played` IS the destination and the bar
// would draw a settled playhead at B; the pinned state pulls the concrete indicator back
// along the delta and part-dissolves the ghost still standing at B. The fill travels with
// the dot, which is why the band has to split at the fill's own edge rather than pick one
// tint for the whole span.
//
// Rows 1-3 — a forward jump 0.28 → 0.72 at 20% / 55% / 90% of the crossing: the ghost fades
//   out as the dot arrives, the band goes ink-behind / lift-ahead of the moving fill edge,
//   and the comet sits BEHIND the dot.
// Row 4 — a backward jump 0.72 → 0.28 mid-crossing, on the mini bar's line grammar.
#Preview("scrub indicators — travel (A→B crossing)", traits: .fixedLayout(width: 1200, height: 760)) {
    ZStack {
        LinearGradient(colors: [.purple, .black], startPoint: .topLeading, endPoint: .bottomTrailing)
            .ignoresSafeArea()
        VStack(spacing: 70) {
            indicatorPreviewBar(played: 0.72, delta: SeekDelta(from: 0.28, to: 0.72))
                .environment(\.seekPulsePreview, .traveling(progress: 0.2, phase: 0.12))
            indicatorPreviewBar(played: 0.72, delta: SeekDelta(from: 0.28, to: 0.72))
                .environment(\.seekPulsePreview, .traveling(progress: 0.55, phase: 0.34))
            indicatorPreviewBar(played: 0.72, delta: SeekDelta(from: 0.28, to: 0.72))
                .environment(\.seekPulsePreview, .traveling(progress: 0.9, phase: 0.55))
            indicatorPreviewBar(played: 0.28, delta: SeekDelta(from: 0.72, to: 0.28),
                                mode: .scrub, playhead: .line)
                .environment(\.seekPulsePreview, .traveling(progress: 0.5, phase: 0.4))
        }
        .padding(60)
    }
    .frame(width: 1200, height: 760)
    .environment(\.colorScheme, .dark)
}

// PHASE 2b — the CHAINED re-scrub: a second gesture over a first seek that never landed. The
// video has been sitting at A0 = 0.28 the whole time (the first commit only ever promised
// B1 = 0.86), so the concrete indicator stays there through the second drag and the second
// commit's crossing runs A0→B2 — never B1→B2, which would launch the dot from a point it has
// never occupied.
//
// Row 1 — the second drag, forward. Solid dot still at A0, and NO comet: a gesture supersedes
//   the flight it interrupts (a `.previewing` stage publishes no span), so only the drag's own
//   soft band is left.
// Row 2 — the same drag reversed past A0, so the ghost sits BEHIND the concrete dot.
// Row 3 — the chained commit's crossing, forward: the dot leaves 0.28, not 0.86.
// Row 4 — the flip. B2 = 0.08 is on the far side of A0, so the same chain yields one clean
//   backward crossing out of A0 on the mini bar's line grammar.
#Preview("scrub indicators — chained re-scrub (unlanded seek)", traits: .fixedLayout(width: 1200, height: 760)) {
    ZStack {
        LinearGradient(colors: [.purple, .black], startPoint: .topLeading, endPoint: .bottomTrailing)
            .ignoresSafeArea()
        VStack(spacing: 70) {
            indicatorPreviewBar(played: 0.60, concrete: 0.28, mode: .scrub, bubble: "1:16:00")
                .environment(\.seekPulsePreview, .dragging)
            indicatorPreviewBar(played: 0.08, concrete: 0.28, mode: .scrub, bubble: "0:10:05")
                .environment(\.seekPulsePreview, .dragging)
            indicatorPreviewBar(played: 0.60, delta: SeekDelta(from: 0.28, to: 0.60))
                .environment(\.seekPulsePreview, .traveling(progress: 0.35, phase: 0.22))
            indicatorPreviewBar(played: 0.08, delta: SeekDelta(from: 0.28, to: 0.08),
                                mode: .scrub, playhead: .line)
                .environment(\.seekPulsePreview, .traveling(progress: 0.45, phase: 0.38))
        }
        .padding(60)
    }
    .frame(width: 1200, height: 760)
    .environment(\.colorScheme, .dark)
}

// PHASE 3 — the comet outliving the crossing: the dot has arrived at B and the trail is still
// sweeping out behind it, frozen mid-sweep (`seekPulsePreview`)
// so a static render can show it at all: the live sweep is a `TimelineView`, and a one-frame
// snapshot catches it at phase 0 with the comet entirely off the segment. `played` equals
// each delta's `to` on purpose — the bar drops any delta that isn't the destination it's
// displaying, so these rows also prove that gate passes for a settled commit.
//
// Row 1 — forward 0.28 → 0.72: the delta is INSIDE the played fill, dimmed with ink, comet
//   travelling left→right toward B. Should read as the fill arriving, never as a gap.
// Row 2 — backward 0.72 → 0.28: the delta sits PAST the fill on bare track, lifted above it,
//   comet travelling right→left. Brighter than track, clearly below the fill.
// Row 3 — the same forward delta under Reduce Motion: the tint band with NO comet.
// Row 4 — a tiny 0.50 → 0.515 delta: below the minimum span, so nothing draws.
#Preview("scrub delta pulse (forward / backward / reduce motion)", traits: .fixedLayout(width: 1200, height: 760)) {
    ZStack {
        LinearGradient(colors: [.purple, .black], startPoint: .topLeading, endPoint: .bottomTrailing)
            .ignoresSafeArea()
        VStack(spacing: 70) {
            indicatorPreviewBar(played: 0.72, delta: SeekDelta(from: 0.28, to: 0.72))
            indicatorPreviewBar(played: 0.28, delta: SeekDelta(from: 0.72, to: 0.28))
            indicatorPreviewBar(played: 0.72, delta: SeekDelta(from: 0.28, to: 0.72))
                .environment(\.seekPulsePreview, .reducedMotion)
            indicatorPreviewBar(played: 0.515, delta: SeekDelta(from: 0.50, to: 0.515))
        }
        .padding(60)
        .environment(\.seekPulsePreview, .sweeping(phase: 0.62))
    }
    .frame(width: 1200, height: 760)
    .environment(\.colorScheme, .dark)
}

// ── The accent previews ─────────────────────────────────────────────────────────────────────
// The four above pin the GEOMETRY of each state in the monochrome fallback; these three pin the
// LOOK of the same states once an artwork accent is in play. Each renders one state across the
// warm hue, the cool hue, and white — so a single render answers both "does the hue read over
// video" and "is the white fallback still the bar we shipped". Since the indicators are FLAT,
// the white row is the pre-accent bar exactly: any difference in it is a regression.

// ACCENT · the drag. What to look for: the concrete bead/sliver stays WHITE, opaque and flat (it
// is the honest position and must not take the poster's colour), while the ghost is a hollow
// silhouette outlined in the accent with a soft light around it, the split band's lift half
// carries the hue, and the bubble reads out in it. No gradient, no highlight, no bevel on either
// indicator — a handle that looks pressable is the bug this preview exists to catch.
#Preview("scrub accent — drag (dot / line × 3 accents)", traits: .fixedLayout(width: 1200, height: 1160)) {
    ZStack {
        LinearGradient(colors: [.purple, .black], startPoint: .topLeading, endPoint: .bottomTrailing)
            .ignoresSafeArea()
        VStack(spacing: 62) {
            ForEach(ScrubAccentPreview.all, id: \.0) { _, accent in
                Group {
                    indicatorPreviewBar(played: 0.72, concrete: 0.28, mode: .scrub,
                                        bubble: "1:31:10")
                    indicatorPreviewBar(played: 0.28, concrete: 0.72, mode: .scrub,
                                        playhead: .line, bubble: "0:35:20")
                }
                .environment(\.scrubAccent, accent)
            }
        }
        .padding(60)
        .environment(\.seekPulsePreview, .dragging)
    }
    .frame(width: 1200, height: 1160)
    .environment(\.colorScheme, .dark)
}

// ACCENT · the crossing and the landing, over TWO backdrops. Rows come in pairs per accent:
// mid-flight at 55% (the bloom is still dark — `ScrubTravel.bloomOnset` holds it off until the
// last 30%) and at touchdown, where the flare is at full and the ghost has dissolved into the
// bead. The two rows of a pair must differ ONLY by the pool of light under the head and the
// ghost's absence.
//
// The two COLUMNS are the point of the second backdrop: the bloom is `.plusLighter`, and the
// finding this preview settles is that additive light must not blend against the movie frame. The
// left column is the darkest frame a seek can land on, the right one the brightest. The flare has
// to read the SAME in both — if the bright column washes it out or the black column blows it up,
// the `compositingGroup()` under the handle is not doing its job.
#Preview("scrub accent — travel + arrival bloom", traits: .fixedLayout(width: 2400, height: 1180)) {
    HStack(spacing: 0) {
        travelBloomColumn(backdrop: .black, caption: "black frame")
        travelBloomColumn(backdrop: Color(white: 0.94), caption: "bright frame")
    }
    .frame(width: 2400, height: 1180)
    .environment(\.colorScheme, .dark)
}

/// One backdrop's worth of the travel/bloom pairs. A function rather than two copies so the two
/// columns can only ever differ by the colour behind them.
private func travelBloomColumn(backdrop: Color, caption: String) -> some View {
    ZStack {
        backdrop.ignoresSafeArea()
        VStack(spacing: 62) {
            Text(caption)
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(backdrop == .black ? .white : .black)
            ForEach(ScrubAccentPreview.all, id: \.0) { _, accent in
                Group {
                    indicatorPreviewBar(played: 0.72, delta: SeekDelta(from: 0.28, to: 0.72))
                        .environment(\.seekPulsePreview, .traveling(progress: 0.55, phase: 0.34))
                    indicatorPreviewBar(played: 0.72, delta: SeekDelta(from: 0.28, to: 0.72))
                        .environment(\.seekPulsePreview, .traveling(progress: 1.0, phase: 0.62))
                }
                .environment(\.scrubAccent, accent)
            }
        }
        .padding(60)
    }
    .frame(width: 1200, height: 1180)
}

// ACCENT · the settle loop, frozen mid-sweep. Per accent: a forward delta (the span lies INSIDE
// the played fill, so the band is ink and the accent arrives as the comet and the breath) and
// a backward one (the span is on bare track, so the band's lift half
// is the accent outright). The last row is Reduce Motion at the warm hue — the static band keeps
// its gentle tint, and there must be NO comet and NO breath anywhere in it.
#Preview("scrub accent — settle loop (ink / lift / reduce motion)", traits: .fixedLayout(width: 1200, height: 1340)) {
    ZStack {
        LinearGradient(colors: [.purple, .black], startPoint: .topLeading, endPoint: .bottomTrailing)
            .ignoresSafeArea()
        VStack(spacing: 62) {
            ForEach(ScrubAccentPreview.all, id: \.0) { _, accent in
                Group {
                    indicatorPreviewBar(played: 0.72, delta: SeekDelta(from: 0.28, to: 0.72))
                    indicatorPreviewBar(played: 0.28, delta: SeekDelta(from: 0.72, to: 0.28),
                                        playhead: .line)
                }
                .environment(\.scrubAccent, accent)
            }
            indicatorPreviewBar(played: 0.72, delta: SeekDelta(from: 0.28, to: 0.72))
                .environment(\.scrubAccent, ScrubAccentPreview.ember)
                .environment(\.seekPulsePreview, .reducedMotion)
        }
        .padding(60)
        .environment(\.seekPulsePreview, .sweeping(phase: 0.62))
    }
    .frame(width: 1200, height: 1340)
    .environment(\.colorScheme, .dark)
}

// Incomplete media (unknown runtime): a dim track with the live elapsed ticking on the
// left, NO total/remaining, NO played fill, NO draggable handle — the honest "playing,
// length unknown, not seekable" form. Compare against the normal bar above it.
#Preview("indeterminate (unknown runtime)") {
    ZStack {
        LinearGradient(colors: [.purple, .black], startPoint: .topLeading, endPoint: .bottomTrailing)
            .ignoresSafeArea()
        VStack(spacing: 90) {
            PlayerProgressBar(metrics: .tv, mode: .normal, indeterminate: false, played: 0.5,
                              buffered: 0.64, elapsed: "1:04:18", remaining: "-1:02:42",
                              elapsedSeconds: 3858, remainingSeconds: 3762)
            PlayerProgressBar(metrics: .tv, mode: .normal, indeterminate: true, played: 0,
                              elapsed: "0:42", remaining: "",
                              elapsedSeconds: 42, remainingSeconds: 0)
        }
        .padding(60)
    }
    .frame(width: 1200, height: 460)
    .environment(\.colorScheme, .dark)
}

#Preview("normal / focused / scrub") {
    ZStack {
        LinearGradient(colors: [.purple, .black], startPoint: .topLeading, endPoint: .bottomTrailing)
            .ignoresSafeArea()
        VStack(spacing: 90) {
            PlayerProgressBar(metrics: .tv, mode: .normal, played: 0.5, buffered: 0.64,
                              elapsed: "1:04:18", remaining: "-1:02:42",
                              elapsedSeconds: 3858, remainingSeconds: 3762,
                              chapters: [0.12, 0.27, 0.41, 0.58, 0.74, 0.89])
            PlayerProgressBar(metrics: .tv, mode: .focused, played: 0.5, buffered: 0.64,
                              elapsed: "1:04:18", remaining: "-1:02:42",
                              elapsedSeconds: 3858, remainingSeconds: 3762,
                              chapters: [0.12, 0.27, 0.41, 0.58, 0.74, 0.89])
            PlayerProgressBar(metrics: .tv, mode: .scrub, playhead: .line,
                              played: 0.72, buffered: 0.81,
                              elapsed: "1:31:10", remaining: "-0:35:50",
                              elapsedSeconds: 5470, remainingSeconds: 2150,
                              chapters: [0.12, 0.27, 0.41, 0.58, 0.74, 0.89],
                              bubbleTime: "1:31:10", bubbleChapter: "Chapter 7 · The Drift")
        }
        .padding(60)
    }
    .frame(width: 1200, height: 700)
    .environment(\.colorScheme, .dark)
}

// The clamp regressions: scrubbed to the extremes at portrait-phone width (the case
// that put the playhead-centred bubble past the screen edges), plus a chapter title
// longer than the bar (the case that drove the bubble wider than the bar and made the
// centring fallback overhang BOTH edges — device-caught on iPad). The bubble must park
// inside the bar's span while the handle sits at the very end; the long title must
// ellipsize at the bar's width, never run past it.
#Preview("scrub bubble edge clamp (phone portrait)") {
    ZStack {
        LinearGradient(colors: [.purple, .black], startPoint: .topLeading, endPoint: .bottomTrailing)
            .ignoresSafeArea()
        VStack(spacing: 120) {
            PlayerProgressBar(metrics: .phone, mode: .scrub, played: 0.003, buffered: 0.1,
                              elapsed: "0:00:21", remaining: "-1:47:52",
                              elapsedSeconds: 21, remainingSeconds: 6472,
                              bubbleTime: "0:00:21", bubbleChapter: "Chapter 1 · Arrival")
            PlayerProgressBar(metrics: .phone, mode: .scrub, played: 0.997, buffered: 1.0,
                              elapsed: "1:47:52", remaining: "-0:00:21",
                              elapsedSeconds: 6472, remainingSeconds: 21,
                              bubbleTime: "1:47:52", bubbleChapter: "Chapter 12 · Credits")
            PlayerProgressBar(metrics: .phone, mode: .scrub, played: 0.45, buffered: 0.6,
                              elapsed: "0:48:32", remaining: "-0:59:20",
                              elapsedSeconds: 2912, remainingSeconds: 3560,
                              bubbleTime: "0:48:32",
                              bubbleChapter: "Chapter 5 · The Improbably Long Chapter Title That Ran Past Both Screen Edges")
        }
        .padding(.horizontal, PlayerMetrics.phonePadX)
    }
    .frame(width: 393, height: 760)
    .environment(\.colorScheme, .dark)
}
