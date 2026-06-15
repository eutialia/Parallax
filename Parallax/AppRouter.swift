import Foundation
import Observation
import ParallaxJellyfin

@Observable
@MainActor
final class AppRouter {
    enum Destination: Hashable {
        /// Session list not loaded yet — avoid showing login (and LAN discovery)
        /// until `ServerStore.load()` finishes.
        case bootstrapping
        case login
        case home
    }

    var destination: Destination = .bootstrapping

    /// Identity of the active server. `RootTabView` keys its per-server view
    /// remount on this so a server switch reloads Home/Library/Search. It lives
    /// here (not in `RootTabView` `@State`) because `ServerStore` is an actor
    /// with no SwiftUI observation: the app-side router is the single source of
    /// truth, updated by every site that changes the active session.
    var activeServerID: ServerID?

    /// Drives the floating settings panel. Presented from the stable `RootView` (above
    /// `RootTabView`'s remount) so switching/adding a server keeps the panel open; lives
    /// here rather than in view `@State` for the same reason `activeServerID` does.
    var presentingSettings: Bool = false

    /// Monotonic counter the roots fold into `libraryReloadToken`.
    private(set) var libraryRevision = 0

    /// Bump to force the roots to rebuild their merged library list when the SET of configured
    /// servers changes without the active Jellyfin session changing (e.g. an SMB server
    /// added/removed). Distinct from a session switch, which already moves `activeServerID`.
    func bumpLibraryRevision() { libraryRevision += 1 }

    /// Reload key for the roots' library `.task`: re-fires on a Jellyfin server switch AND on a
    /// server-set change. The full-tab `.id(activeServerID)` remount stays keyed on the session
    /// only — a revision bump rebuilds `entries` without tearing down every tab.
    var libraryReloadToken: String { "\(activeServerID?.rawValue ?? "-")#\(libraryRevision)" }

    func updateForCurrentSession(_ session: Session?) {
        destination = (session == nil) ? .login : .home
        activeServerID = session?.id
        // Signed out of the last server → the panel has nothing to manage and would
        // otherwise float over the bare login root.
        if session == nil { presentingSettings = false }
    }

    func goToLogin() {
        destination = .login
        activeServerID = nil
        presentingSettings = false
    }
}
