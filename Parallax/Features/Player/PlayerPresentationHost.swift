#if !os(tvOS)
import SwiftUI

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
    /// Vertical travel of the player surface in points: 0 = settled full screen,
    /// container height = parked offscreen below the window.
    var travel: CGFloat = 0
    /// True once the present spring has landed. Gates the pull gesture: a drag's
    /// travel is the finger's absolute translation, so engaging while the surface
    /// is still mid-flight would teleport it to the (small) translation value.
    var isSettled = false
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

    /// One spring for present and dismiss — matches the system cover feel.
    private static let spring = Animation.spring(duration: 0.45, bounce: 0)

    var body: some View {
        // GeometryReader (not onGeometryChange) on purpose: it stays full-size
        // while NOTHING is mounted, so the present always has a real height to
        // park the surface at — an empty ZStack would measure zero and the first
        // frame would mount the player already settled (no slide).
        GeometryReader { geo in
            let height = geo.size.height
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
                            withAnimation(Self.spring) {
                                presentation.travel = 0
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
                sync(height: height)
            }
        }
    }

    private func sync(height: CGFloat) {
        if let request = playback.request {
            guard mounted?.id != request.id else { return }
            // Park offscreen in the same commit that mounts; onAppear slides in.
            presentation.travel = height
            presentation.isSettled = false
            mounted = request
        } else {
            guard mounted != nil else { return }
            presentation.isSettled = false
            // From wherever the surface is — 0 after a Close tap, the finger's
            // drop point after a committed pull, the live spring's current value
            // if the present is still in flight (retargeted, velocity kept) —
            // down past the bottom edge, then unmount. The completion fires
            // exactly once even if the animation is interrupted, so the player
            // can never linger unmounted-but-visible.
            withAnimation(Self.spring) {
                presentation.travel = height
            } completion: {
                // If a present raced this slide-out (the presenter's grace
                // latch makes that near-impossible, but it's wall-clock), the
                // new player owns the slot — a stale completion must not
                // unmount it.
                guard playback.request == nil else { return }
                mounted = nil
                presentation.travel = 0
            }
        }
    }
}
#endif
