import SwiftUI
import ParallaxJellyfin
import ParallaxCore

struct FocusRootView: View {
    @Environment(AppRouter.self) private var router
    @Environment(AppDependencies.self) private var deps
    @Environment(LaunchGate.self) private var launchGate
    @State private var selectedTab: AppTab = .home
    @State private var session: Session?
    @State private var libraries: [MediaCollection] = []
    @State private var homeViewModel: HomeViewModel?

    var body: some View {
        Group {
            // Gate the sidebar+content behind a full-screen launch surface until the first
            // screen's data is in hand — the structural fix for the menu owning focus during
            // the cold-launch fetch. The `.sidebarAdaptable` menu can only relinquish focus to
            // content that has a focusable view; while Home is a skeleton it has none, so the
            // menu stays focused and expanded. Withholding the TabView until the hero exists
            // sidesteps that (matches the Apple TV app's spinner-then-everything-together
            // launch). `session` + `homeViewModel` both land in one update below, so they are
            // the readiness signal — no separate flag needed.
            if let session, let homeViewModel {
                tabView(session: session, homeViewModel: homeViewModel)
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
        .task(id: router.activeServerID) {
            guard router.activeServerID != nil else { return }
            guard let session = await deps.serverStore.active else { return }
            let repo = await deps.jellyfinLibraryRepoFactory(session)
            // Load the sidebar's libraries and Home's feed concurrently, then reveal once both
            // settle — so the UI appears whole, with the hero already focusable.
            let vm = HomeViewModel(repo: repo)
            async let libs: [MediaCollection] = (try? await repo.collections()) ?? []
            async let homeLoaded: Void = vm.load()
            self.libraries = await libs
            _ = await homeLoaded
            self.session = session
            self.homeViewModel = vm
            // Both gates settle here: the TabView mounts (hero focusable from
            // its first frame) and the launch stage's sync-hold releases, so
            // the iris opens onto the ready UI.
            launchGate.markContentReady()
        }
    }

    private func tabView(session: Session, homeViewModel: HomeViewModel) -> some View {
        TabView(selection: $selectedTab) {
            Tab("Home", systemImage: "house", value: AppTab.home) {
                NavigationStack {
                    HomeView(preloaded: (session, homeViewModel))
                }
            }
            Tab("Search", systemImage: "magnifyingglass", value: AppTab.search) {
                NavigationStack {
                    JellyfinSearchView()
                }
            }

            // No "Library" tab on tvOS: the sidebar's Libraries section IS the browser — each entry
            // drills straight to its grid. With no list to push a drill-down from, the selected
            // library tab's own label drives the collapsed sidebar's top-left name (the old
            // drill-down path showed a stale "Library" there).
            if !libraries.isEmpty {
                TabSection("Libraries") {
                    ForEach(libraries) { library in
                        Tab(library.name, systemImage: library.collectionType.symbolName, value: AppTab.collection(library.id)) {
                            NavigationStack {
                                LibraryGridView(collection: library, session: session)
                            }
                        }
                    }
                    Tab("Favorites", systemImage: "heart", value: AppTab.favorites) {
                        NavigationStack {
                            LibraryGridView(scope: .favorites, title: "Favorites", session: session)
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