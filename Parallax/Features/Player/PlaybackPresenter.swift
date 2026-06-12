import Foundation
import Observation
import ParallaxJellyfin

/// App-level "play this item now" coordinator. Every play intent — episode taps
/// (Home, Search, a library grid, a season's episode list) and the detail pages'
/// Play buttons — lands here, and ONE root-level host presents the player (see
/// `RootView`): an overlay layer on iOS, a `fullScreenCover` on tvOS. Playback
/// is never tied to a tab's navigation stack, and on iOS the app's live UI stays
/// genuinely underneath the player — that's what the pull-to-dismiss reveals.
@Observable
@MainActor
final class PlaybackPresenter {
    struct Request: Identifiable {
        enum Target {
            /// Detail already in hand (a detail page's Play button) — no refetch.
            case detail(ItemDetail)
            /// Play by id — the player resolves it under its loading veil.
            case itemID(ItemID)
        }

        let id = UUID()
        let target: Target
        let session: Session
    }

    private(set) var request: Request?

    /// True while a dismissed player's removal transition is still on screen.
    /// On iOS the outgoing PlayerView stays mounted (engine tearing down, audio
    /// session deactivating) for the whole slide-out, and the live UI underneath
    /// is already tappable — so without this latch a play() in that window would
    /// mount a SECOND player whose audio the first one's async deactivate() then
    /// kills. The cover used to absorb those taps for free; the overlay must not
    /// accept them either.
    private var isTearingDown = false

    /// A play that arrived during the teardown grace. The underlying UI is
    /// already live while the old player slides out, so a tap there is a
    /// deliberate next pick, not a stray touch — dropping it read as a dead
    /// button. Held (latest wins) and presented once the grace expires.
    private var pendingRequest: Request?

    /// Latch hold: the host's dismiss spring (0.45s) plus teardown headroom.
    /// Injectable (tests pass .zero) — `.zero` disables the latch. Pure state
    /// here: the present/dismiss ANIMATION is `PlayerPresentationHost`'s
    /// business — this class never knows how the player moves.
    private let teardownGrace: Duration

    init(teardownGrace: Duration = .milliseconds(600)) {
        self.teardownGrace = teardownGrace
    }

    func play(_ itemID: ItemID, in session: Session) {
        present(.init(target: .itemID(itemID), session: session))
    }

    /// Play an already-loaded detail (e.g. the movie detail's Play button).
    func play(_ detail: ItemDetail, in session: Session) {
        present(.init(target: .detail(detail), session: session))
    }

    func dismiss() {
        guard request != nil else { return }
        request = nil
        guard teardownGrace > .zero else { return }
        isTearingDown = true
        Task { [weak self, teardownGrace] in
            try? await Task.sleep(for: teardownGrace)
            guard let self else { return }
            self.isTearingDown = false
            if let pending = self.pendingRequest {
                self.pendingRequest = nil
                self.present(pending)
            }
        }
    }

    private func present(_ new: Request) {
        // Ignore a play() while a player is already presented — a fresh
        // Request.id would tear it down and re-present (flicker + duplicate
        // stop). That can only come from a tap race; drop it, like the old
        // cover dropped mid-dismissal touches.
        guard request == nil else { return }
        // During the slide-out the engine is still tearing down — mounting a
        // second player now would have its audio killed by the first one's
        // async deactivate(). Hold the pick and present it after the grace.
        guard !isTearingDown else {
            pendingRequest = new
            return
        }
        request = new
    }
}
