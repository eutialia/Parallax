import SwiftUI
import ParallaxJellyfin
import ParallaxCore

struct FocusRootView: View {
    @Environment(AppRouter.self) private var router
    @Environment(AppDependencies.self) private var deps
    @Environment(LaunchGate.self) private var launchGate
    @Environment(UserDataActions.self) private var userDataActions
    @State private var selectedTab: AppTab = .home
    @State private var session: Session?
    /// One group per configured source, in server add order — the sidebar's titled sections.
    /// Libraries are never merged across servers, so a group is exactly one server's libraries.
    @State private var groups: [LibraryGroup] = []
    /// Sources whose library listing failed this pass — the sidebar is missing THOSE servers'
    /// libraries because the network is down, not because they have none. Gates
    /// `.recoversFromOffline` so they repopulate on reconnect; healthy servers and the local SMB
    /// shares are never re-pulled. Home recovers itself via `HomeView`'s own modifier (it shares
    /// the preloaded view model), so recovery here re-resolves only the libraries.
    @State private var failedSourceIDs: Set<MediaSourceID> = []
    @State private var homeViewModel: HomeViewModel?
    /// Flips true once the first library load settles — the readiness signal that reveals the tab
    /// host. Independent of `session`: an SMB-only config has no Jellyfin session yet is fully ready
    /// (its libraries are in `entries`). `@State`, so the `.id(activeServerID)` remount on a Jellyfin
    /// switch resets it and re-gates behind the launch surface.
    @State private var isReady = false

    var body: some View {
        Group {
            // Gate the sidebar+content behind a full-screen launch surface until the first library
            // load settles — the structural fix for the menu owning focus during the cold-launch
            // fetch. The `.sidebarAdaptable` menu can only relinquish focus to content that has a
            // focusable view; while Home is a skeleton it has none, so the menu stays focused and
            // expanded. Withholding the TabView until the data is in hand sidesteps that (matches the
            // Apple TV app's spinner-then-everything-together launch). For an SMB-only config Home is
            // the (non-focusable) "no feed" placeholder, so the sidebar lands focus expanded on the
            // libraries — the correct entry point when there's no Jellyfin hero to focus.
            if isReady {
                tabView
            } else {
                AppLaunchView()
            }
        }
        .environment(\.appIdiom, .tv)
        .id(router.activeServerID)
        .onChange(of: router.presentingSettings) { _, presenting in
            guard presenting else { return }
            selectedTab = .settings
            router.presentingSettings = false
        }
        #if DEBUG
        // Land on the Settings tab from a bare `simctl launch` — Home's hero carousel swallows
        // directional input, so scripted UI verification can't reach the sidebar reliably.
        .task {
            guard ProcessInfo.processInfo.arguments.contains("-openSettingsTab") else { return }
            selectedTab = .settings
        }
        #endif
        // Keyed on the reload token (server switch + SMB add/remove), matching RootTabView.
        // The `.id(activeServerID)` remount above stays session-only.
        .task(id: router.libraryReloadToken) {
            // Bail only while there's NO source at all (the transient bootstrapping window); the
            // token re-fires once a source resolves. An SMB-only config has `activeServerID == nil`
            // but `hasAuxiliarySources == true`, so it passes here — where the old `activeServerID`
            // gate stranded it on the launch spinner.
            guard router.hasAnySource else { return }
            // Home's feed (hero / Continue Watching / Next Up) is Jellyfin-only, and aggregates
            // EVERY signed-in server — so the model is built from the full session list, not the
            // active one. SMB-only (no sessions): no model; Home renders `HomeUnavailableView` and
            // the libraries come from the sidebar.
            var vm: HomeViewModel?
            let feeds = await HomeViewModel.Feed.all(
                for: await deps.serverStore.sessions,
                repoFactory: deps.jellyfinLibraryRepoFactory
            )
            if !feeds.isEmpty {
                vm = HomeViewModel(feeds: feeds, userDataActions: userDataActions, snapshots: deps.snapshots)
            }
            // Stale-while-revalidate: reveal on the last known sidebar + feed if they're on disk,
            // rather than holding the launch surface for the network. The loads below then run
            // exactly as before and replace what's on screen.
            await revealFromCache(vm)
            // Load the sidebar's libraries and Home's feed concurrently, then reveal once both
            // settle — so the UI appears whole, with the hero (if any) already focusable.
            // `loadLibraries()` commits entries/session/stall under its own cancellation check; it's
            // the shared recovery path too, so the launch and reconnect loads never drift.
            async let librariesLoaded: Void = loadLibraries()
            if let vm {
                async let homeLoaded: Void = vm.load()
                _ = await (librariesLoaded, homeLoaded)
            } else {
                await librariesLoaded
            }
            // A token change cancels this task and starts a fresh one; a now-stale snapshot must not
            // clobber the newer state.
            guard !Task.isCancelled else { return }
            self.homeViewModel = vm
            self.isReady = true
            // The launch stage's sync-hold releases here; the iris opens onto the ready UI.
            launchGate.markContentReady()
        }
        // Repopulate the sidebar's Jellyfin libraries when the network returns (or the app
        // foregrounds online) after a launch that couldn't reach the server. Gated on
        // the failed-source set so healthy servers — and the local SMB shares — are never re-pulled; the
        // reload token doesn't move on a reconnect, so without this the libraries stayed gone until a
        // server switch. Home recovers separately via its own modifier. Event-based, no pull-to-refresh.
        .recoversFromOffline(isStalled: !failedSourceIDs.isEmpty) { await loadLibraries() }
    }

    /// Put the cached sidebar and Home feed on screen and open the launch surface on them, without
    /// waiting for a single request. Runs before the real loads, which then replace both.
    ///
    /// The reveal stays gated on there being something FOCUSABLE — cached library rows, a hydrated
    /// (non-empty) hero, or both. With neither, this returns having changed nothing and the launch
    /// surface stays up until the network pass settles, exactly as before: showing the
    /// `.sidebarAdaptable` TabView with nothing to focus is the failure this gate exists to prevent.
    private func revealFromCache(_ model: HomeViewModel?) async {
        let sources = await MergedLibrary.SourceState.read(from: deps.serverStore)
        let cachedGroups = await sources.cachedGroups(snapshots: deps.snapshots)
        let hydratedHome = await model?.hydrateFromCache() ?? false
        let active = await deps.serverStore.active
        // Cancellation re-checked AFTER the last suspension, like every other commit site here:
        // a token move (server switch, sign-in) cancels this task mid-hop, and a stale pass must
        // not flip `isReady` — and above all must not release the one-shot launch gate over the
        // superseding pass's still-loading screen.
        guard !Task.isCancelled, !cachedGroups.isEmpty || hydratedHome else { return }
        if !cachedGroups.isEmpty { groups = cachedGroups }
        // `tabView` needs BOTH a session and a model to hand Home its preloaded feed, so they're
        // committed together — and the model goes over whether or not its own cache hit, because
        // it is already built and the launch task is loading it. Left nil, Home would mount
        // self-loading and duplicate that fetch against the same servers.
        session = active
        homeViewModel = model
        isReady = true
        launchGate.markContentReady()
    }

    /// Resolve + commit just the sidebar's merged library list. Shared by the launch `.task` (run
    /// concurrently with the Home feed) and offline recovery, so the two never drift. Reads its own
    /// `active`/hidden/servers snapshot and commits under a cancellation check: a token change
    /// cancels the launch task, and a now-stale snapshot must not clobber newer state (or snap
    /// selection off a tab still valid in the latest entries). Does NOT touch `isReady` / the launch
    /// gate / the Home model — those are the launch task's to commit once both loads settle.
    private func loadLibraries() async {
        guard router.hasAnySource else { groups = []; session = nil; failedSourceIDs = []; return }
        let sources = await MergedLibrary.SourceState.read(from: deps.serverStore)
        let outcome = await sources.resolve(
            retaining: groups,
            snapshots: deps.snapshots,
            jellyfinRepo: deps.mediaRepoFactory
        )
        let active = await deps.serverStore.active
        guard !Task.isCancelled else { return }
        session = active
        groups = outcome.groups
        failedSourceIDs = outcome.failedSourceIDs
        // If the selected library tab's backing entry just vanished, snap to Home so the tab host
        // isn't left on a gone tab (shared with RootTabView via `snappedIfStale`).
        selectedTab = selectedTab.snappedIfStale(against: outcome.entries)
    }

    /// One library row in a server's sidebar section. Extracted with an EXPLICIT
    /// `some TabContent<AppTab>` return type, and not inlined, for two reasons that bit here:
    /// the annotation pins `TabValue` to non-optional `AppTab` (left to infer inside two nested
    /// `ForEach`es, `TabSection` resolves to its optional-selection overload and the whole
    /// `TabContentBuilder` stops matching), and pulling the `NavigationStack` + destination out of
    /// the doubly-nested builder keeps the remaining expression under the type-checker's limit.
    /// Without it the roots fail as `TabView` silently falls back to its legacy `ViewBuilder`
    /// overload and reports "Tab … does not conform to 'View'" against the FIRST tab in the file.
    private func libraryTab(for entry: LibraryEntry) -> some TabContent<AppTab> {
        Tab(entry.collection.name, systemImage: entry.tabSymbolName, value: AppTab.collection(entry.id)) {
            NavigationStack {
                // SMB shares drill into the folder browser; Jellyfin collections into the poster
                // grid (shared with the iPhone list — one dispatch site).
                libraryEntryDestination(for: entry)
            }
        }
    }

    private var tabView: some View {
        TabView(selection: $selectedTab) {
            Tab("Home", systemImage: "house", value: AppTab.home) {
                NavigationStack {
                    // Jellyfin: adopt the launch gate's preloaded feed (hero focusable from frame 1).
                    // SMB-only: the self-loading HomeView routes to `HomeUnavailableView`.
                    if let session, let homeViewModel {
                        HomeView(preloaded: (session, homeViewModel))
                    } else {
                        HomeView()
                    }
                }
            }
            // Search is Jellyfin-backed (SMB has no search index) — omitted in an SMB-only config
            // rather than shown as a permanently-empty tab. `role: .search` = the system search
            // tab; JellyfinSearchView's `.searchable` renders the HIG search screen inside it.
            if router.hasSearchableSource {
                Tab(value: AppTab.search, role: .search) {
                    NavigationStack {
                        JellyfinSearchView()
                    }
                }
            }

            // No "Library" tab on tvOS: the sidebar's Libraries section IS the browser — each entry
            // drills straight to its grid. With no list to push a drill-down from, the selected
            // library tab's own label drives the collapsed sidebar's top-left name (the old
            // drill-down path showed a stale "Library" there).
            // Favorites is a cross-SERVER virtual library, so it sits at top level rather than
            // inside a server's section (which would claim it belongs to that server). Jellyfin
            // concept — omitted SMB-only. Mirrors RootTabView's placement.
            // `session != nil`, not `let session`: `FavoritesView` resolves every server itself, so
            // the session is only a presence test here — binding it left an unused value.
            if session != nil {
                Tab("Favorites", systemImage: "heart", value: AppTab.favorites) {
                    NavigationStack {
                        FavoritesView()
                    }
                }
            }

            // One collapsible section per server, in the order the user added them — libraries are
            // never merged across servers, so two servers that both expose "Movies" stay two rows
            // under two headers. A single configured source keeps the plain "Libraries" title.
            ForEach(groups) { group in
                TabSection(groups.sectionTitle(for: group)) {
                    ForEach(group.entries) { libraryTab(for: $0) }
                }
            }

            Tab("Settings", systemImage: "gearshape", value: AppTab.settings) {
                NavigationStack {
                    SettingsView()
                }
            }
        }
        .tabViewStyle(.sidebarAdaptable)
    }
}