import SwiftUI
import ParallaxJellyfin
import ParallaxCore

/// The iPhone Library tab's shell: resolves every configured source's libraries in ONE
/// `MergedLibrary.resolve` pass — the same resolver the iPad sidebar and tvOS focus root use —
/// and owns the load / empty / failure states. `LibraryListView` below is pure presentation.
///
/// There is no longer a separate SMB-only list: an SMB-only config is just a resolution with no
/// Jellyfin groups and no Favorites card, so one view covers both. (The old split existed
/// because the merged list anchored on a live `Session` for its Jellyfin view model; that view
/// model is gone.)
struct LibraryHostView: View {
    @Environment(AppDependencies.self) private var deps
    @Environment(AppRouter.self) private var router
    /// One group per source, in server add order.
    @State private var groups: [LibraryGroup] = []
    /// Whether any Jellyfin server is signed in — gates the cross-server Favorites card (favorites
    /// are a Jellyfin concept). `FavoritesView` resolves the servers themselves.
    @State private var hasJellyfinSource = false
    /// Sources whose library listing failed this pass. Non-empty drives offline recovery; it also
    /// distinguishes "every server is unreachable" (a real failure worth a message) from "no
    /// server has any visible library" (an empty state).
    @State private var failedSourceIDs: Set<MediaSourceID> = []
    @State private var isResolvingSource = true

    var body: some View {
        Group {
            if !groups.isEmpty {
                LibraryListView(groups: groups, showsFavorites: hasJellyfinSource)
                    .navigationTitle("Library")
                // Note: no `.navigationSubtitle(session.serverName)`. It named a single server
                // above a list that already mixed sources, and with several servers there is no
                // one name to put there. Server identity now rides the per-server section headers
                // inside the list, which is where it actually applies.
            } else if isResolvingSource {
                LibraryListLoadingPlaceholder()
                    .navigationTitle("Library")
            } else if !failedSourceIDs.isEmpty {
                // Every source that could have contributed failed to list — offline, not empty.
                StatusStateView.failure(
                    "Couldn't load libraries",
                    message: "Parallax couldn't reach your servers. Check your connection and try again."
                )
                .navigationTitle("Library")
            } else {
                StatusStateView(
                    title: "No libraries",
                    systemImage: "rectangle.stack.badge.xmark",
                    message: "Add a Jellyfin or SMB source in Settings to browse your library."
                )
                .navigationTitle("Library")
            }
        }
        .screenFloor()
        // Keyed on the reload token (not a single server id): a Jellyfin add/switch/sign-out
        // (token's id part) AND an SMB add/remove (token's revision part) both rebuild the groups
        // — mirrors how RootTabView / FocusRootView refresh theirs, so an added server shows up
        // without a relaunch.
        .task(id: router.libraryReloadToken) { await load() }
        // Repopulate when the network returns (or the app foregrounds online) after a pass that
        // couldn't reach a server. Gated on the failed set so healthy groups — and the local SMB
        // shares — are never re-pulled.
        .recoversFromOffline(isStalled: !failedSourceIDs.isEmpty) { await load() }
    }

    /// Resolve + commit every source's libraries. Captures into locals across the awaits, then
    /// commits under a cancellation check: a token change cancels this task and starts a fresh
    /// one, and a stale snapshot must not clobber the newer state.
    private func load() async {
        // Clear, don't just early-return: dropping the last source without a remount must not
        // leave a stale list rendered (mirrors the roots' tasks).
        guard router.hasAnySource else {
            groups = []; hasJellyfinSource = false; failedSourceIDs = []; isResolvingSource = false
            return
        }
        // One read of the sessions, shared by the resolve and the Favorites gate — two reads are
        // two actor hops that can also disagree with each other.
        let sessions = await deps.serverStore.sessions
        let outcome = await MergedLibrary.resolve(
            sessions: sessions,
            servers: await deps.serverStore.servers,
            hiddenCollectionIDs: await deps.serverStore.allHiddenCollectionIDs,
            jellyfinRepo: deps.mediaRepoFactory
        )
        // NOT a `defer`: on the cancelled path the placeholder must stay up. Clearing it there
        // would drop the view to the "No libraries — add a source" empty state (groups is still
        // empty) for the whole of the superseding pass.
        guard !Task.isCancelled else { return }
        groups = outcome.groups
        hasJellyfinSource = !sessions.isEmpty
        failedSourceIDs = outcome.failedSourceIDs
        isResolvingSource = false
    }
}
