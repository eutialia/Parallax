import SwiftUI

extension View {
    /// Auto-recover a view that's stuck on a blocking error once the network returns or the app
    /// comes back to the foreground — the event-based alternative to pull-to-refresh.
    ///
    /// Fires `action` on **either** recovery edge, but only while `isStalled` is true (the view is
    /// showing a full-screen error with no content):
    /// - the network goes offline → online, or
    /// - the app returns to `.active` from the background while a network path already exists
    ///   (cold launch's own activation is not a return — the first load only just ran).
    ///
    /// A healthy, loaded view is never disturbed — `isStalled` gates every fire. Attach this to a
    /// view's STABLE container (alongside `.task`), not inside the `.failed` branch, so its
    /// observers stay mounted across state flips.
    func recoversFromOffline(isStalled: Bool, action: @escaping () async -> Void) -> some View {
        modifier(RecoverFromOffline(isStalled: isStalled, action: action))
    }
}

private struct RecoverFromOffline: ViewModifier {
    let isStalled: Bool
    let action: () async -> Void

    // Optional so previews (and any host without the monitor injected) no-op instead of trapping
    // on a missing `@Environment` Observable. When nil, `isOnline == true` checks fail and recovery
    // simply never fires.
    @Environment(ConnectivityMonitor.self) private var connectivity: ConnectivityMonitor?
    @Environment(\.scenePhase) private var scenePhase
    /// Synchronous latch: dedupes a same-frame double-fire of the two `onChange`s and blocks
    /// re-entry while a recovery `action` is in flight.
    @State private var isRecovering = false
    /// Cold launch settles through the same inactive→active transition as a foreground return, so
    /// the previous phase alone can't tell them apart. Without this latch a level that stalled
    /// during launch got an immediate second listing on the launch settle — and the first one's
    /// in-flight SMB call is uncancellable, so both ran on the wire. Mirrors `RefreshOnForeground`.
    @State private var hasBeenBackgrounded = false

    func body(content: Content) -> some View {
        content
            .onChange(of: connectivity?.isOnline) { wasOnline, isOnline in
                // Reconnect edge only: offline (false) → online (true).
                if wasOnline == false, isOnline == true { recover() }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .background { hasBeenBackgrounded = true }
                guard phase == .active else { return }
                defer { hasBeenBackgrounded = false }
                // Foreground return while a path already exists — re-try the stuck load. (A return
                // while still offline needs no handling: the reconnect edge above fires when the
                // path comes back.)
                if hasBeenBackgrounded, connectivity?.isOnline == true { recover() }
            }
    }

    private func recover() {
        guard isStalled, !isRecovering else { return }
        isRecovering = true
        Task {
            await action()
            isRecovering = false
        }
    }
}
