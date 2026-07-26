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

    /// Fingerprint of the configured source SET (see `SourceSnapshot.setIdentity`), folded into
    /// `libraryReloadToken`. This is what makes the roots rebuild when a source is added or removed
    /// WITHOUT the active session moving — adding a second Jellyfin server, or signing out of a
    /// non-active one. Both used to leave every term of the token untouched, so the sidebar kept
    /// the stale group list until the next launch.
    private(set) var sourceSetIdentity = ""

    /// Any browsable source at all — a live Jellyfin session OR an auxiliary (SMB) source.
    /// The tab roots gate their per-source loads on this (was `activeServerID != nil`,
    /// which stranded SMB-only configs on an endless skeleton).
    var hasAnySource: Bool { activeServerID != nil || hasAuxiliarySources }

    /// Whether ANY configured source can answer a search — the Search tab's visibility gate.
    ///
    /// Only Jellyfin servers can today, so this is currently "is a Jellyfin session signed in".
    /// It's stated as its own question rather than inlined as `activeServerID != nil` because
    /// that's the seam: when SMB grows a filename index, its `SearchProviding.canSearch` flips
    /// true and this predicate is the ONE place that has to learn about it — the roots, the view
    /// model, and the results view all already work off the provider list.
    var hasSearchableSource: Bool { activeServerID != nil }

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
    /// `sourceSetIdentity` is load-bearing here, not cosmetic, for two reasons:
    ///
    /// 1. It covers every change to the SET of sources — including ones that leave the active
    ///    session and the auxiliary-source flag alone (a second Jellyfin server added; a
    ///    non-active one signed out). Those are invisible to the other terms.
    /// 2. A cold launch renders the roots during `.bootstrapping` (RootView shows RootTabView for
    ///    both `.bootstrapping` and `.home`), so the library task fires once BEFORE
    ///    `ServerStore.load()` resolves — with no source it bails to an empty list. For an SMB-only
    ///    config the active id stays nil and the revision stays 0 across the bootstrap→home flip, so
    ///    without a set term the token never changes and that empty result sticks (empty sidebar).
    ///    The identity goes from "" to the real fingerprint, re-firing the task. (This subsumes the
    ///    `hasAuxiliarySources` term it replaced, which only handled case 2.)
    ///
    /// `libraryRevision` remains for changes to the CONTENTS of an unchanged source set — a
    /// "Visible Libraries" edit, or an SMB share re-selection — which no source fingerprint can see.
    var libraryReloadToken: String {
        "\(activeServerID?.rawValue ?? "-")#\(libraryRevision)#\(sourceSetIdentity)"
    }

    /// Point the router at the current source configuration. `.home` needs ANY source (a live
    /// Jellyfin session OR ≥1 auxiliary source); only a fully empty config routes to `.login`.
    ///
    /// Takes the WHOLE snapshot rather than a session plus a flag: every caller then hands over one
    /// self-consistent read of the store, and the roots' reload token maintains itself. The previous
    /// signature made source-set changes depend on each mutation site also remembering to call
    /// `bumpLibraryRevision()`, and two of them didn't — which is how a newly added second Jellyfin
    /// server stayed missing from the sidebar until relaunch.
    func updateForSources(_ snapshot: SourceSnapshot) {
        activeServerID = snapshot.activeSessionID
        hasAuxiliarySources = snapshot.hasAuxiliarySources
        sourceSetIdentity = snapshot.setIdentity
        destination = hasAnySource ? .home : .login
        // Signed out of the last source → the panel has nothing to manage and would
        // otherwise float over the bare login root.
        if !hasAnySource { presentingSettings = false }
    }
}
