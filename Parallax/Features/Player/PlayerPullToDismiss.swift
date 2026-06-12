#if !os(tvOS)
import SwiftUI

/// Pull-down-to-dismiss for the full-screen player — the touch analog of the top
/// bar's down-chevron Close, and the same motion: the WHOLE player (video, HUD,
/// black floor — one layer, exactly what the Close button slides away) tracks
/// the finger 1:1. Committing takes deliberate travel — a good fraction of the
/// screen height, or a genuine downward fling — so a stray swipe can't kill
/// playback; anything short springs back. The finger writes the SAME
/// `PlayerPresentation.travel` the host's present/dismiss springs animate, so a
/// committed pull hands off seamlessly: the dismiss spring starts exactly where
/// the finger dropped the surface (see `PlayerPresentationHost`).
///
/// Attach to the player's entire content (floor included): offsetting only the
/// video surface left the floor parked, which read as two layers — a card you
/// pull and a backdrop that "catches up" when the dismissal fires.
///
/// Sheet semantics: the WHOLE surface is the drag handle — a partial start
/// zone read as arbitrary in practice — except drag-interactive chrome. Views
/// like the scrub bar mark their touch target with `pullToDismissExclusion()`,
/// and a drag that starts inside one never engages the pull, so grabbing the
/// progress bar always means seeking. What else keeps it honest: only a
/// clearly vertical, downward drag engages (sideways stays free, scrubbing is
/// horizontal), the gesture is `simultaneous` with a 24pt minimum so chrome
/// taps and buttons keep working, and call sites gate `isEnabled` off while a
/// track menu or drag-scrub owns the screen.
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
    private let commitTravel: CGFloat = 220
    private let flingTravel: CGFloat = 100
    private let flingVelocity: CGFloat = 1600

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
            // 1:1, translation only — matching the Close button's slide. No
            // scale/corner "card" treatment: that detached the surface from
            // the floor and broke the one-layer illusion. This is the ONLY
            // offset on the surface: present/dismiss animate the same value.
            .offset(y: max(0, presentation.travel))
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
                withAnimation(cancelSpring) { presentation.travel = 0 }
            }
            .onPreferenceChange(PullExclusionZonesKey.self) { exclusionZones = $0 }
            // Outermost on purpose: ancestor of the gesture's node AND of the
            // exclusion reporters inside the content, so both resolve here.
            .coordinateSpace(name: Self.coordinateSpace)
    }

    private var cancelSpring: Animation {
        reduceMotion ? .easeOut(duration: 0.2) : .spring(duration: 0.4, bounce: 0.22)
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
                    // Engage only for a clearly vertical, downward drag —
                    // sideways swipes stay free for future gestures, and a
                    // horizontal scrub can never start a pull — that did NOT
                    // start on drag-interactive chrome (the scrub bar's
                    // territory is seeking, never the sheet pull).
                    guard value.translation.height > 0,
                          value.translation.height > abs(value.translation.width) * 1.2,
                          !startsInExclusionZone(value.startLocation)
                    else { return }
                    isTracking = true
                }
                presentation.travel = value.translation.height
                isArmed = presentation.travel >= commitTravel    // haptic rides .sensoryFeedback
            }
            .onEnded { value in
                guard isTracking else { return }
                isTracking = false
                let endTravel = value.translation.height
                let commits = endTravel >= commitTravel
                    || (endTravel >= flingTravel && value.velocity.height >= flingVelocity)
                if commits, isEnabled {
                    // isArmed stays as-is: resetting it here would fire the
                    // disarm tick right as the player dismisses. Leave the
                    // surface where the finger dropped it; the host's dismiss
                    // spring continues the motion from this exact value.
                    onDismiss()
                } else {
                    isArmed = false
                    withAnimation(cancelSpring) { presentation.travel = 0 }
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
