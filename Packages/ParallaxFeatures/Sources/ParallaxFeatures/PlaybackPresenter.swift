import Foundation
import Observation
import ParallaxJellyfin
import ParallaxCore

/// App-level "play this item now" coordinator. Every play intent — episode taps
/// (Home, Search, a library grid, a season's episode list) and the detail pages'
/// Play buttons — lands here, and ONE root-level host presents the player (see
/// `RootView`): an overlay layer on iOS, a `fullScreenCover` on tvOS. Playback
/// is never tied to a tab's navigation stack, and on iOS the app's live UI stays
/// genuinely underneath the player — that's what the pull-to-dismiss reveals.
@Observable
@MainActor
public final class PlaybackPresenter {
    public struct Request: Identifiable {
        public enum Target {
            /// Detail already in hand (a detail page's Play button) — no refetch.
            /// Carries its Jellyfin `Session`; SMB has none (`.smb` below).
            /// `fromBeginning` is the explicit restart intent (the context menu's
            /// "Play from Beginning" — Task 4): true skips any saved resume position.
            case detail(ItemDetail, Session, fromBeginning: Bool)
            /// Play by id — the player resolves it under its loading veil. Carries
            /// the Jellyfin `Session` it resolves against and the same restart intent.
            case itemID(ItemID, Session, fromBeginning: Bool)
            /// Play a browsed SMB file — the player resolves the `SMBPlaybackItem`
            /// (Keychain + sidecar subs) under its loading veil, no `Session` involved.
            /// No restart intent: SMB tracks no server-side resume state.
            case smb(Item, SMBServerRef)
        }

        public let id = UUID()
        public let target: Target
    }

    public private(set) var request: Request?

    /// The presented session's exit hand-off (`PlayerViewModel.beginExit`), registered by
    /// `AppModel.runPlayer` for its request and consumed by the `dismiss()` that clears it, so a
    /// session that resumes late can't hand its exit to a newer player.
    ///
    /// Not every dismissal goes through the player's own close button: the tvOS cover
    /// dismisses itself through its item binding, a server switch closes the player from
    /// `AppModel`, and the debug lab dismisses from a script. Those paths used to drop
    /// straight into the slide-out with the engine still running, so audio played on for
    /// the whole animation: exactly the bug `endAudio()` fixes for the close button.
    /// Routing the hand-off through here means the presenter is the one place that has to
    /// know.
    ///
    /// Weak-captured at the registration site: the presenter outlives every session.
    /// `@ObservationIgnored` because it is a wire, not state; no view reads it.
    @ObservationIgnored private var exitHandler: (@MainActor () -> Void)?

    /// Registers `handler` as the exit of the request `requestID`. Ignored unless that request is
    /// the one presented.
    public func setExitHandler(for requestID: Request.ID, _ handler: @escaping @MainActor () -> Void) {
        guard request?.id == requestID else { return }
        exitHandler = handler
    }

    /// True while the player owns the screen — presented OR still sliding out during the
    /// teardown grace. The iOS overlay leaves the live UI mounted and tappable underneath
    /// for the whole slide-out (see `isTearingDown`), so anything that must stay inert
    /// beneath the player (e.g. RootView disabling the tab host so the iPad sidebar
    /// gesture can't steal taps) has to gate on THIS, not the raw `request` — which clears
    /// the instant dismiss begins, re-arming those gestures mid-dismissal.
    public var isPlayerPresent: Bool { request != nil || isTearingDown }

    /// True while a dismissed player's removal transition is still on screen.
    /// On iOS the outgoing PlayerView stays mounted for the whole slide-out, and the
    /// live UI underneath is already tappable — so without this latch a play() in that
    /// window would slide a second player in over the outgoing one. The audio session
    /// is `deviceHolds`' business, not this latch's.
    private var isTearingDown = false

    /// A play that arrived during the teardown grace or while a closed session still holds the
    /// device. The underlying UI is already live while the old player slides out, so a tap there
    /// is a deliberate next pick, not a stray touch — dropping it read as a dead button. Held
    /// (latest wins) and presented once the grace expires and the device is free.
    private var pendingRequest: Request?

    /// Sessions whose engines are still draining or whose audio session is still active. The next
    /// player activates that same audio session, so a pick opens only once this is empty: an
    /// engine teardown has no fixed length (VLC's can take seconds), and a deactivation landing
    /// after the next activation silences the new player.
    private var deviceHolds: Set<DeviceHold> = []

    /// Latch hold: the host's dismiss spring (0.45s) plus headroom, so the next player never
    /// slides in over the outgoing one. The device itself is `deviceHolds`'s.
    /// Injectable (tests pass .zero) — `.zero` disables the latch. Pure state
    /// here: the present/dismiss ANIMATION is `PlayerPresentationHost`'s
    /// business — this class never knows how the player moves.
    private let teardownGrace: Duration
    private let clock: any Clock<Duration>

    public init(teardownGrace: Duration = .milliseconds(600), clock: any Clock<Duration>) {
        self.teardownGrace = teardownGrace
        self.clock = clock
    }

    /// `fromBeginning` defaults false so every existing tap-to-resume call site is
    /// unaffected — only the context menu's "Play from Beginning" (Task 4) passes true.
    public func play(_ itemID: ItemID, in session: Session, fromBeginning: Bool = false) {
        present(.init(target: .itemID(itemID, session, fromBeginning: fromBeginning)))
    }

    /// Play an already-loaded detail (e.g. the movie detail's Play button).
    /// `fromBeginning` — see `play(_ itemID:in:fromBeginning:)`.
    public func play(_ detail: ItemDetail, in session: Session, fromBeginning: Bool = false) {
        present(.init(target: .detail(detail, session, fromBeginning: fromBeginning)))
    }

    /// Play a browsed SMB file. The player resolves the `SMBPlaybackItem` under its
    /// loading veil (via `AppServices.smbPlaybackResolver`), so a resolution
    /// failure lands on the failure scrim like the Jellyfin id path.
    public func playSMB(_ item: Item, ref: SMBServerRef) {
        present(.init(target: .smb(item, ref)))
    }

    /// One player session's claim on the engines and the audio session.
    struct DeviceHold: Hashable {
        private let id = UUID()
    }

    /// A session holds the engines and the audio session from here until `releaseDevice(_:)`.
    func holdDevice() -> DeviceHold {
        let hold = DeviceHold()
        deviceHolds.insert(hold)
        return hold
    }

    /// The session has drained its engines and released audio. Repeat calls are no-ops, so a
    /// session can release early and again when it returns.
    func releaseDevice(_ hold: DeviceHold) {
        guard deviceHolds.remove(hold) != nil else { return }
        presentPendingIfSettled()
    }

    public func dismiss() {
        guard request != nil else { return }
        // Fence + end audio BEFORE the request clears: clearing it is what starts the
        // slide-out, and audio must already be gone by then. Consumed here so a second
        // dismiss (the tvOS cover's binding firing after the close button's) can't call
        // into a session that's already handed off (`beginExit()` is idempotent anyway).
        exitHandler?()
        exitHandler = nil
        request = nil
        guard teardownGrace > .zero else { return }
        isTearingDown = true
        Task { [weak self, teardownGrace, clock] in
            try? await clock.sleep(for: teardownGrace)
            guard let self else { return }
            self.isTearingDown = false
            self.presentPendingIfSettled()
        }
    }

    private func presentPendingIfSettled() {
        guard !isTearingDown, deviceHolds.isEmpty, let pending = pendingRequest else { return }
        pendingRequest = nil
        present(pending)
    }

    private func present(_ new: Request) {
        // Ignore a play() while a player is already presented — a fresh
        // Request.id would tear it down and re-present (flicker + duplicate
        // stop). That can only come from a tap race; drop it, like the old
        // cover dropped mid-dismissal touches.
        guard request == nil else { return }
        // During the slide-out, or while a closed session still drains: mounting a second
        // player now would have its audio killed by the first one's deactivate(). Hold the
        // pick and present it once both are over.
        guard !isTearingDown, deviceHolds.isEmpty else {
            pendingRequest = new
            return
        }
        request = new
    }
}
