import SwiftUI

extension View {
    /// Auto-recover a view that's stuck on a blocking error once the network returns or the app
    /// comes back to the foreground — the event-based alternative to pull-to-refresh.
    ///
    /// Fires `action` on **either** recovery edge, but only while `isStalled` is true (the view is
    /// showing a full-screen error with no content):
    /// - the network goes offline → online, or
    /// - the app returns to `.active` while a network path already exists.
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

    func body(content: Content) -> some View {
        content
            .onChange(of: connectivity?.isOnline) { wasOnline, isOnline in
                // Reconnect edge only: offline (false) → online (true).
                if wasOnline == false, isOnline == true { recover() }
            }
            .onChange(of: scenePhase) { _, phase in
                // Foreground return while a path already exists — re-try the stuck load. (A return
                // while still offline needs no handling: the reconnect edge above fires when the
                // path comes back.)
                if phase == .active, connectivity?.isOnline == true { recover() }
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
