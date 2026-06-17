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

    /// Identity of the active Jellyfin server. `RootTabView` keys its per-server view
    /// remount on this so a server switch reloads Home/Library/Search. It lives
    /// here (not in `RootTabView` `@State`) because `ServerStore` is an actor
    /// with no SwiftUI observation: the app-side router is the single source of
    /// truth, updated by every site that changes the active session. nil when no
    /// Jellyfin session is signed in — including a valid SMB-only configuration.
    var activeServerID: ServerID?

    /// Whether any non-Jellyfin source (SMB today; local/other later) is configured.
    /// Combined with `activeServerID` to choose login vs home: a config with no Jellyfin
    /// session but ≥1 SMB server is a real home (browse those libraries), not a login
    /// dead-end. Maintained by every site that updates the configured source set.
    private(set) var hasAuxiliarySources = false

    /// Any browsable source at all — a live Jellyfin session OR an auxiliary (SMB) source.
    /// The tab roots gate their per-source loads on this (was `activeServerID != nil`,
    /// which stranded SMB-only configs on an endless skeleton).
    var hasAnySource: Bool { activeServerID != nil || hasAuxiliarySources }

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

    /// Reload key for the roots' library `.task`: re-fires on a Jellyfin server switch, a
    /// server-set change (revision bump), AND when auxiliary (SMB) sources appear/disappear. The
    /// full-tab `.id(activeServerID)` remount stays keyed on the session only — a revision bump
    /// rebuilds `entries` without tearing down every tab.
    ///
    /// `hasAuxiliarySources` is load-bearing here, not cosmetic: a cold launch renders the roots
    /// during `.bootstrapping` (RootView shows RootTabView for both `.bootstrapping` and `.home`),
    /// so the library task fires once BEFORE `ServerStore.load()` resolves — with no source it bails
    /// to empty `entries`. For an SMB-only config the active id stays nil and the revision stays 0
    /// across the bootstrap→home flip, so without this term the token never changes and that empty
    /// result sticks (empty sidebar). Folding in the aux-source flag re-fires the task once SMB
    /// presence is known. (A Jellyfin login already moves the id, so it re-fires regardless.)
    var libraryReloadToken: String {
        "\(activeServerID?.rawValue ?? "-")#\(libraryRevision)#\(hasAuxiliarySources ? "aux" : "-")"
    }

    /// Point the router at the current source set. `.home` needs ANY source (a live
    /// Jellyfin session OR ≥1 auxiliary source); only a fully empty config routes to
    /// `.login`. `activeServerID` follows the Jellyfin session (the per-server remount
    /// key); an SMB-only change moves `hasAuxiliarySources` instead, which a
    /// `bumpLibraryRevision()` folds into the roots' reload token without a full remount.
    func updateForSources(activeSession: Session?, hasAuxiliarySources: Bool) {
        activeServerID = activeSession?.id
        self.hasAuxiliarySources = hasAuxiliarySources
        destination = hasAnySource ? .home : .login
        // Signed out of the last source → the panel has nothing to manage and would
        // otherwise float over the bare login root.
        if !hasAnySource { presentingSettings = false }
    }
}
