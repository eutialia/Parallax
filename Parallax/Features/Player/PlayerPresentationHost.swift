#if !os(tvOS)
import SwiftUI
import UIKit

/// Shared state for the iOS player layer: ONE vertical travel value that every
/// motion writes — the present spring (height → 0), the pull-to-dismiss finger
/// (0 → wherever it drags), and the dismiss spring (current → height). Because
/// they all drive the same animatable state, every hand-off is continuous by
/// construction: a Close tap mid-present retargets the live spring from its
/// current position, and a committed pull's slide-out starts exactly where the
/// finger left the surface.
@Observable
@MainActor
final class PlayerPresentation {
    /// Surface translation from its settled full-screen rest, in points. `.zero` = settled;
    /// `(0, height)` = parked offscreen below (the present/dismiss slide). During an
    /// interactive drag it's the live finger translation on BOTH axes — the player lifts
    /// into a card you can move any direction (the system-sheet / library-detail dismiss
    /// feel), not the old pull-straight-down rubber band. ONE value every motion writes
    /// (present spring, Close/commit slide, the drag), so every hand-off is continuous.
    var offset: CGSize = .zero
    /// True once the present spring has landed. Gates the pull gesture: a drag's offset is
    /// the finger's absolute translation, so engaging while the surface is still mid-flight
    /// would teleport it to the (small) translation value.
    var isSettled = false
    /// True while a finger is dragging the surface (and through the spring-back / fly-out
    /// that follows). Surfaced to the HUD as `pullDragging`, where it FREEZES the chrome:
    /// the auto-hide is suspended (so the status-bar inset can't collapse mid-drag) and the
    /// top bar switches to a safe-area-bounded inset mode so it rides the card rigidly
    /// instead of shearing. Present and the Close-button dismiss leave it false (pure slide).
    var isDragging = false
}

/// Hosts the iOS player as an explicit offset-driven layer over the live UI.
///
/// Deliberately NOT `if let` + `.transition(.move(edge: .bottom))` with a scoped
/// `.animation(value:)`: a transition's placement spring exists only in the one
/// transaction where the request id changes, and this player generates a storm
/// of mid-flight commits inside the moving subtree — `viewModel` lands ~150ms in
/// and structurally swaps the playback surface, the AVPlayerLayer representable
/// mounts when the engine arrives, status-bar/home-indicator/safe-area flips
/// land non-animated. Any of them could re-dirty the transitioning placement,
/// detach the in-flight spring, and park the surface mid-screen until the id
/// changed again (the on-device "player stuck half-presented" bug; its siblings
/// were the slide-up silently dropping to a pop and the dismiss cutting short).
/// A state-driven offset has no placement to clobber: unrelated re-renders leave
/// an in-flight `travel` animation running, and unmounting waits for the dismiss
/// spring's completion instead of racing it.
struct PlayerPresentationHost: View {
    @Environment(PlaybackPresenter.self) private var playback

    /// The request whose player is in the tree. Lags `playback.request` on
    /// dismiss by the slide-out (content must outlive the request to animate
    /// out); the presenter's teardown grace latch covers that overlap.
    @State private var mounted: PlaybackPresenter.Request?
    @State private var presentation = PlayerPresentation()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// One spring for present and dismiss — matches the system cover feel.
    private static let spring = Animation.spring(duration: 0.45, bounce: 0)
    /// Reduce Motion swaps the full-height slide spring for a short cross-fade-speed
    /// ease so the player still appears/dismisses without the large vertical travel.
    private static let reducedSpring = Animation.easeInOut(duration: 0.2)

    private var presentAnimation: Animation { reduceMotion ? Self.reducedSpring : Self.spring }

    var body: some View {
        // GeometryReader (not onGeometryChange) on purpose: it stays full-size
        // while NOTHING is mounted, so the present always has a real height to
        // park the surface at — an empty ZStack would measure zero and the first
        // frame would mount the player already settled (no slide).
        GeometryReader { geo in
            // FULL window height (the reader is safe-area-bounded), or the dismiss slide
            // stops a safe-area short and leaves the full-bleed player peeking at the bottom
            // edge — it slides, pauses on that strip, then the unmount snaps it away (the
            // "step"). Parking the present at the full height keeps the slide-in symmetric.
            let height = geo.size.height + geo.safeAreaInsets.top + geo.safeAreaInsets.bottom
            // How far the dismiss slide must travel to clear the screen. On iPhone the
            // dismissal itself rotates the window back to portrait (see `sync`), so the
            // slide computed in landscape must still clear the PORTRAIT height — the
            // window's larger physical dimension. iPad never rotates on dismiss (the
            // orientation lock is a no-op there), so it keeps the exact height and the
            // slide-out speed the present spring matches.
            let dismissTravel = UIDevice.current.userInterfaceIdiom == .phone
                ? max(height, geo.size.width + geo.safeAreaInsets.leading + geo.safeAreaInsets.trailing)
                : height
            ZStack {
                if let request = mounted {
                    PlayerView(request: request)
                        // Identity per request: even if a present ever lands
                        // while the outgoing player is still sliding out (the
                        // presenter's latch should prevent it, but it's
                        // wall-clock), the slot can't silently reuse the old
                        // view's @State — B gets a fresh viewModel AND a fresh
                        // onAppear, so it can never mount parked offscreen
                        // with no slide-in armed.
                        .id(request.id)
                        .environment(presentation)
                        // The UI underneath stays mounted (that's the point), so
                        // tell assistive tech the player owns the screen.
                        .accessibilityElement(children: .contain)
                        .accessibilityAddTraits(.isModal)
                        // Slide in from onAppear, one commit AFTER mounting
                        // parked offscreen: an animation written in the same
                        // transaction as the insertion wouldn't animate (a fresh
                        // view's first values are its identity).
                        .onAppear {
                            withAnimation(presentAnimation) {
                                presentation.offset = .zero
                            } completion: {
                                // A dismiss that retargeted this spring
                                // mid-present must not re-arm the pull on a
                                // surface that's already leaving.
                                if playback.request != nil {
                                    presentation.isSettled = true
                                }
                            }
                        }
                }
            }
            .onChange(of: playback.request?.id) { _, _ in
                sync(height: height, dismissTravel: dismissTravel)
            }
        }
        // The player never keyboard-avoids: nothing in it takes text input, and the
        // keyboard safe-area region can outlive the keyboard in this overlay's
        // sidebarAdaptable/UISplitViewController ancestry (observed on an 11" iPad,
        // portrait: a keyboard-height bottom inset with no keyboard on screen pushed
        // the safe-area-relative HUD rows — scrubber + chips — up to the letterbox
        // edge while full-bleed siblings sat correctly). Excluding the region here
        // covers every mounted surface at once — HUD, seek bar, track panels — while
        // container edges (status bar, home indicator) keep flowing normally.
        .ignoresSafeArea(.keyboard)
    }

    private func sync(height: CGFloat, dismissTravel: CGFloat) {
        if let request = playback.request {
            guard mounted?.id != request.id else { return }
            // Park offscreen in the same commit that mounts; onAppear slides in.
            presentation.offset = CGSize(width: 0, height: height)
            presentation.isSettled = false
            presentation.isDragging = false
            mounted = request
        } else {
            guard mounted != nil else { return }
            // Release the orientation lock the moment dismissal BEGINS — not in the
            // player's onDisappear, which this host defers until the slide-out's
            // completion. The browse UI underneath is visible (only disabled) for the
            // whole slide, so a completion-time release showed it sideways for the
            // full 0.45s and then snap-rotated to portrait (the dismiss "flash") —
            // and a backgrounding mid-slide froze the spring's clock, reopening the
            // app on landscape browse. Rotating now means the window turns portrait
            // WHILE the card slides out (hence `dismissTravel` clearing the portrait
            // height). onDisappear keeps an idempotent release as the backstop for
            // unmounts that never flip `request` (server switch).
            OrientationController.shared.releasePlayerLock()
            presentation.isSettled = false
            // From wherever the surface is — .zero after a Close tap, the finger's
            // drop point after a committed pull (the card slides on out from there,
            // still lifted), the live spring's current value if the present is still
            // in flight (retargeted, velocity kept) — down past the bottom edge, then
            // unmount. The completion fires exactly once even if the animation is
            // interrupted, so the player can never linger unmounted-but-visible.
            withAnimation(presentAnimation) {
                presentation.offset = CGSize(width: 0, height: dismissTravel)
            } completion: {
                // The slide-out landed: any drag state is stale now, so clear it
                // unconditionally — even if the race guard below bails, isDragging
                // must not survive into the next present.
                presentation.isDragging = false
                // If a present raced this slide-out (the presenter's grace
                // latch makes that near-impossible, but it's wall-clock), the
                // new player owns the slot — a stale completion must not
                // unmount it.
                guard playback.request == nil else { return }
                mounted = nil
                presentation.offset = .zero
            }
        }
    }
}
#endif
