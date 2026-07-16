import SwiftUI
import ParallaxJellyfin
import ParallaxCore

struct FocusRootView: View {
    @Environment(AppRouter.self) private var router
    @Environment(AppDependencies.self) private var deps
    @Environment(LaunchGate.self) private var launchGate
    @State private var selectedTab: AppTab = .home
    @State private var session: Session?
    @State private var entries: [LibraryEntry] = []
    /// True while a Jellyfin session is active but its `collections()` fetch failed — the sidebar
    /// shows SMB-only (or nothing) because the network is down, not because the server has no
    /// libraries. Gates `.recoversFromOffline` so the libraries repopulate on reconnect; the local
    /// SMB shares are unaffected. Home recovers itself via `HomeView`'s own modifier (it shares the
    /// preloaded view model), so recovery here re-resolves only the libraries.
    @State private var librariesStalled = false
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
        // Keyed on the reload token (server switch + SMB add/remove), matching RootTabView.
        // The `.id(activeServerID)` remount above stays session-only.
        .task(id: router.libraryReloadToken) {
            // Bail only while there's NO source at all (the transient bootstrapping window); the
            // token re-fires once a source resolves. An SMB-only config has `activeServerID == nil`
            // but `hasAuxiliarySources == true`, so it passes here — where the old `activeServerID`
            // gate stranded it on the launch spinner.
            guard router.hasAnySource else { return }
            // Home's feed (hero / Continue Watching / Next Up) is Jellyfin-only, so build its model
            // only for a live session — its concrete repo carries the feed methods the merged list
            // doesn't. SMB-only: no model; Home renders `HomeUnavailableView` and the libraries come
            // from the sidebar.
            var vm: HomeViewModel?
            if let active = await deps.serverStore.active {
                vm = HomeViewModel(repo: await deps.jellyfinLibraryRepoFactory(active))
            }
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
        // `librariesStalled` so a healthy list — and the local SMB shares — are never re-pulled; the
        // reload token doesn't move on a reconnect, so without this the libraries stayed gone until a
        // server switch. Home recovers separately via its own modifier. Event-based, no pull-to-refresh.
        .recoversFromOffline(isStalled: librariesStalled) { await loadLibraries() }
    }

    /// Resolve + commit just the sidebar's merged library list. Shared by the launch `.task` (run
    /// concurrently with the Home feed) and offline recovery, so the two never drift. Reads its own
    /// `active`/hidden/servers snapshot and commits under a cancellation check: a token change
    /// cancels the launch task, and a now-stale snapshot must not clobber newer state (or snap
    /// selection off a tab still valid in the latest entries). Does NOT touch `isReady` / the launch
    /// gate / the Home model — those are the launch task's to commit once both loads settle.
    private func loadLibraries() async {
        guard router.hasAnySource else { entries = []; session = nil; librariesStalled = false; return }
        let active = await deps.serverStore.active
        var hiddenJellyfin: Set<String> = []
        if let active { hiddenJellyfin = await deps.serverStore.hiddenCollectionIDs(for: active.id) }
        let outcome = await MergedLibrary.resolve(
            jellyfinSession: active,
            smbServers: await deps.serverStore.servers,
            hiddenJellyfinCollectionIDs: hiddenJellyfin,
            jellyfinRepo: deps.mediaRepoFactory
        )
        guard !Task.isCancelled else { return }
        session = active
        entries = outcome.entries
        librariesStalled = outcome.jellyfinCollectionsFailed
        // If the selected library tab's backing entry just vanished, snap to Home so the tab host
        // isn't left on a gone tab (shared with RootTabView via `snappedIfStale`).
        selectedTab = selectedTab.snappedIfStale(against: outcome.entries)
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
            if session != nil {
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
            if !entries.isEmpty {
                TabSection("Libraries") {
                    ForEach(entries) { entry in
                        Tab(entry.collection.name, systemImage: entry.tabSymbolName, value: AppTab.collection(entry.id)) {
                            NavigationStack {
                                // SMB shares drill into the folder browser; Jellyfin collections into
                                // the poster grid (shared with the iPhone list — one dispatch site).
                                libraryEntryDestination(for: entry)
                            }
                        }
                    }
                    // Favorites is a Jellyfin concept (cross-library favorites) — omitted SMB-only.
                    if let session {
                        Tab("Favorites", systemImage: "heart", value: AppTab.favorites) {
                            NavigationStack {
                                LibraryGridView(scope: .favorites, title: "Favorites", session: session)
                            }
                        }
                    }
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