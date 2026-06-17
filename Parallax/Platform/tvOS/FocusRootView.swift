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
            let active = await deps.serverStore.active
            // Home's feed (hero / Continue Watching / Next Up) is Jellyfin-only, so build its model
            // only for a live session — its concrete repo carries the feed methods the merged list
            // doesn't. SMB-only: no model; Home renders `HomeUnavailableView` and the libraries come
            // from the sidebar. The merged list builds via `mediaRepoFactory` either way (nil session
            // contributes no Jellyfin collections, every SMB server folds in).
            var vm: HomeViewModel?
            if let active {
                vm = HomeViewModel(repo: await deps.jellyfinLibraryRepoFactory(active))
            }
            // Load the sidebar's libraries and Home's feed concurrently, then reveal once both
            // settle — so the UI appears whole, with the hero (if any) already focusable.
            async let libs: [LibraryEntry] = MergedLibrary.entries(
                jellyfinSession: active,
                smbServers: await deps.serverStore.servers,
                repoFactory: deps.mediaRepoFactory
            )
            let merged: [LibraryEntry]
            if let vm {
                async let homeLoaded: Void = vm.load()
                merged = await libs
                _ = await homeLoaded
            } else {
                merged = await libs
            }
            // A token change cancels this task and starts a fresh one; a now-stale snapshot must not
            // clobber the newer state (mirrors RootTabView — captured into locals across the awaits,
            // committed under one cancellation check).
            guard !Task.isCancelled else { return }
            self.entries = merged
            self.session = active
            self.homeViewModel = vm
            // If the selected library tab's backing entry just vanished, snap to Home so the tab host
            // isn't left on a gone tab. The `.id(activeServerID)` remount resets selection on a
            // Jellyfin switch/sign-out, but removing ONE of several SMB servers keeps `activeServerID`
            // nil (no remount) while `entries` rebuilds without that library — the only path here
            // (same guard RootTabView carries).
            if case .collection(let ref) = selectedTab, !merged.contains(where: { $0.id == ref }) {
                selectedTab = .home
            }
            self.isReady = true
            // The launch stage's sync-hold releases here; the iris opens onto the ready UI.
            launchGate.markContentReady()
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
            // rather than shown as a permanently-empty tab.
            if session != nil {
                Tab("Search", systemImage: "magnifyingglass", value: AppTab.search) {
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
                        Tab(entry.collection.name, systemImage: entry.collection.collectionType.symbolName, value: AppTab.collection(entry.id)) {
                            NavigationStack {
                                LibraryGridView(collection: entry.collection, source: entry.source)
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