#if !os(tvOS)
import SwiftUI

/// Interactive drag-to-dismiss for the full-screen player — the touch analog of the
/// top bar's down-chevron Close, with the system-sheet / library-detail feel: a downward
/// swipe LIFTS the whole player (video, HUD, black floor — one layer) into a card that
/// then follows the finger in ANY direction, so you can drag it around, not just pull it
/// straight down. Release past a deliberate DOWNWARD threshold (a good fraction of the
/// screen, or a real downward fling) to dismiss; anything else springs the card back to
/// rest. The finger writes the SAME `PlayerPresentation.offset` the host's present/dismiss
/// springs animate, so a committed pull hands off seamlessly: the dismiss spring continues
/// from exactly where the finger dropped the card (see `PlayerPresentationHost`).
///
/// Attach to the player's entire content (floor included): offsetting only the
/// video surface left the floor parked, which read as two layers — a card you
/// pull and a backdrop that "catches up" when the dismissal fires. The travel is a PURE
/// translation, deliberately no scale: a `scaleEffect` distributes to the full-bleed video
/// and safe-area HUD as independent geometries (and won't unify the AVPlayerLayer), so the
/// card would shrink unevenly — a uniform offset is the one transform that moves the whole
/// player rigidly (see `body`).
///
/// Sheet semantics: the WHOLE surface is the drag handle — a partial start
/// zone read as arbitrary in practice — except drag-interactive chrome and the top edge.
/// Views like the scrub bar mark their touch target with `pullToDismissExclusion()`, and
/// a drag that starts inside one never engages the pull, so grabbing the progress bar
/// always means seeking. The top `topSystemEdgeBand` is likewise reserved for the system,
/// so a top-edge swipe opens Control Center / Notification Center without moving the card
/// (the second half of Apple's behavior — see that constant). What else keeps it honest:
/// only a clearly vertical, downward drag ENGAGES the pull (sideways stays free for the
/// focus engine / future gestures, scrubbing is horizontal) — but once engaged the card
/// moves freely; the gesture is `simultaneous` with a 24pt minimum so chrome taps and
/// buttons keep working, and call sites gate `isEnabled` off while a track menu or
/// drag-scrub owns the screen.
struct PlayerPullToDismiss: ViewModifier {
    /// Name of the coordinate space the exclusion rects and the drag's
    /// locations share (the modifier's outermost node).
    static let coordinateSpace = "playerPullToDismiss"

    /// Host-owned travel state the finger drives 1:1 (`PlayerPresentationHost`
    /// animates the same value for present/dismiss). Engagement is gated on
    /// `isSettled`: a drag's travel is the finger's absolute translation, so
    /// grabbing a surface still mid-present-spring would teleport it.
    var presentation: PlayerPresentation
    var isEnabled: Bool
    /// Whether exclusion zones apply — false while the chrome is hidden (the
    /// bar still REPORTS its frame then, since the HUD stays mounted at
    /// opacity 0, but it isn't hit-testable, so the pull may claim its band).
    var exclusionsActive: Bool
    let onDismiss: () -> Void

    /// Finger travel needed to commit — deliberate by design ("more travel than
    /// a flick"). A fast downward fling commits earlier, like every system sheet.
    /// Commit stays DOWNWARD-biased even though the card drags freely: you can move it
    /// around, but only a real downward pull (or downward fling) dismisses — anything
    /// else springs back, exactly like a sheet.
    private let commitTravel: CGFloat = 220
    private let flingTravel: CGFloat = 100
    private let flingVelocity: CGFloat = 1600

    /// Top band (from the surface's top, which is the screen top) that the pull RESERVES
    /// for the system: a drag starting here never engages the card, so a top-edge swipe
    /// goes cleanly to Control Center / Notification Center without budging the player —
    /// the half of Apple's behavior that the no-`defersSystemGestures` change alone doesn't
    /// give (the OS owns the edge, but the app's own gesture must also stand down there, or
    /// the card twitches as the system cancels it). Below the band the surface is the pull
    /// handle as before. ~44pt covers the system edge-pan zone with margin in both the
    /// status-bar idiom (origin sits below it, so its swipes read as negative y, also
    /// excluded) and landscape (no status bar, origin at the screen top).
    private static let topSystemEdgeBand: CGFloat = 44

    @State private var isTracking = false
    /// Past the commit threshold — haptic fires on the way in, release dismisses.
    @State private var isArmed = false
    /// Cancellation sentinel: `.updating` keeps it true while the drag is live,
    /// and the system resets it when the gesture ends OR IS CANCELLED. A
    /// cancelled drag (the notification-shade grabber stealing a top-edge pull,
    /// an incoming call) fires neither onChanged nor onEnded — without this
    /// watcher the surface stayed parked at `travel`, two-thirds down a live
    /// player.
    @GestureState private var isLivePull = false
    /// No-pull territory (the scrub bar's touch target), in `coordinateSpace`.
    @State private var exclusionZones: [CGRect] = []
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            // The card's 2D travel — a render transform on the content, rendered HERE,
            // INSIDE PlayerView. Counter-intuitively rigider than rendering it at the host:
            // an inside render-offset does NOT move PlayerView's frame, so the system never
            // re-resolves its safe area mid-drag and the safe-area-bounded HUD (top bar,
            // bottom rows) rides it rigidly. At the host the moving frame made the system
            // recompute the safe area and the bars sheared. The present/dismiss springs
            // animate this SAME value. Pure translation, no lift/scale: a `scaleEffect`
            // distributes to the full-bleed video and safe-area HUD as independent
            // geometries (and won't unify the AVPlayerLayer), so the card shrinks unevenly —
            // a uniform offset is the one transform that moves the whole player rigidly.
            .offset(presentation.offset)
            // Crossing the commit point in either direction ticks — pull past
            // it to feel "release will close", ease back to feel the cancel.
            .sensoryFeedback(trigger: isArmed) { _, nowArmed in
                .impact(weight: nowArmed ? .medium : .light)
            }
            .simultaneousGesture(dismissDrag)
            .onChange(of: isLivePull) { _, live in
                // Sentinel dropped while we still think we're tracking ⇒ the
                // drag was cancelled out from under us — onEnded never came.
                // Run the cancel path so the surface can't strand mid-screen.
                guard !live, isTracking else { return }
                isTracking = false
                isArmed = false
                withAnimation(cancelSpring) { presentation.offset = .zero } completion: {
                    // Stale-completion guard: a new drag may have engaged before this
                    // spring-back landed (it re-sets isTracking/isDragging true) — don't
                    // clear isDragging out from under the live drag.
                    if !isTracking { presentation.isDragging = false }
                }
            }
            .onPreferenceChange(PullExclusionZonesKey.self) { exclusionZones = $0 }
            // Outermost on purpose: ancestor of the gesture's node AND of the
            // exclusion reporters inside the content, so both resolve here.
            .coordinateSpace(name: Self.coordinateSpace)
    }

    /// Spring-back when a drag is released without committing (and the cancellation
    /// sentinel's path). `bounce: 0` — critically damped, NO overshoot — is load-bearing
    /// now that the surface offset is unclamped 2D (`.offset(presentation.offset)`): the old
    /// pull-straight-down code clamped to `max(0, travel)`, so a bouncy spring's overshoot
    /// PAST rest (the card crossing `.zero` upward) was clipped to 0 and never seen. With the
    /// clamp gone, any `bounce > 0` makes the card visibly shoot up past its rest position —
    /// revealing the live UI at the bottom edge — before settling back down. Don't restore the
    /// bounce: it would re-introduce that glitch. The card must return to rest without crossing it.
    private var cancelSpring: Animation {
        reduceMotion ? .easeOut(duration: 0.2) : .spring(duration: 0.4, bounce: 0)
    }

    private func startsInExclusionZone(_ start: CGPoint) -> Bool {
        exclusionsActive && exclusionZones.contains { $0.contains(start) }
    }

    private var dismissDrag: some Gesture {
        // 24pt before recognition: taps and the chrome's buttons stay instant,
        // and a resting finger never starts a pull.
        DragGesture(minimumDistance: 24, coordinateSpace: .named(Self.coordinateSpace))
            .updating($isLivePull) { _, live, _ in live = true }
            .onChanged { value in
                guard isEnabled, presentation.isSettled else { return }
                if !isTracking {
                    // ENGAGE only for a clearly vertical, downward drag — sideways swipes
                    // stay free for future gestures, and a horizontal scrub can never start
                    // a pull — that did NOT start on drag-interactive chrome (the scrub
                    // bar's territory is seeking, never the sheet pull). Once engaged the
                    // card moves freely (below), but ENGAGEMENT needs a deliberate
                    // downward intent.
                    guard value.translation.height > 0,
                          value.translation.height > abs(value.translation.width) * 1.2,
                          value.startLocation.y > Self.topSystemEdgeBand,
                          !startsInExclusionZone(value.startLocation)
                    else { return }
                    isTracking = true
                    presentation.isDragging = true
                }
                // 2D — the card follows the finger any direction now that it's engaged.
                presentation.offset = value.translation
                isArmed = value.translation.height >= commitTravel    // haptic rides .sensoryFeedback
            }
            .onEnded { value in
                guard isTracking else { return }
                isTracking = false
                let endTravel = value.translation.height
                let commits = endTravel >= commitTravel
                    || (endTravel >= flingTravel && value.velocity.height >= flingVelocity)
                if commits, isEnabled {
                    // isArmed / isDragging stay as-is: resetting them here would fire the
                    // disarm tick right as it dismisses. Leave the card where the finger
                    // dropped it; the host's dismiss spring continues the motion from this
                    // exact value, and resets `isDragging` once it has unmounted.
                    onDismiss()
                } else {
                    isArmed = false
                    withAnimation(cancelSpring) { presentation.offset = .zero } completion: {
                        // Stale-completion guard: see the cancellation path above.
                        if !isTracking { presentation.isDragging = false }
                    }
                }
            }
    }
}

/// Frames (in `PlayerPullToDismiss.coordinateSpace`) where a drag must never
/// start a pull — drag-interactive chrome like the scrub bar.
private struct PullExclusionZonesKey: PreferenceKey {
    static let defaultValue: [CGRect] = []
    static func reduce(value: inout [CGRect], nextValue: () -> [CGRect]) {
        value.append(contentsOf: nextValue())
    }
}

private struct PullExclusionReporter: ViewModifier {
    /// Extra reach above the layout frame, matching the view's extended hit
    /// shape (the scrub bar's `TopExtendedRectangle`) so the exclusion covers
    /// exactly what the finger can grab, not just what's drawn.
    let extendingTop: CGFloat
    @State private var zone: CGRect = .null

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGRect.self) {
                $0.frame(in: .named(PlayerPullToDismiss.coordinateSpace))
            } action: { frame in
                zone = CGRect(
                    x: frame.minX, y: frame.minY - extendingTop,
                    width: frame.width, height: frame.height + extendingTop
                )
            }
            .preference(key: PullExclusionZonesKey.self, value: zone.isNull ? [] : [zone])
    }
}

extension View {
    /// Pull down anywhere on the surface to dismiss the player. See `PlayerPullToDismiss`.
    func playerPullToDismiss(
        presentation: PlayerPresentation, isEnabled: Bool, exclusionsActive: Bool,
        onDismiss: @escaping () -> Void
    ) -> some View {
        modifier(PlayerPullToDismiss(
            presentation: presentation, isEnabled: isEnabled,
            exclusionsActive: exclusionsActive, onDismiss: onDismiss
        ))
    }

    /// Mark this view's touch target as no-pull territory (see `PlayerPullToDismiss`).
    func pullToDismissExclusion(extendingTop: CGFloat = 0) -> some View {
        modifier(PullExclusionReporter(extendingTop: extendingTop))
    }
}
#endif
