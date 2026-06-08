import SwiftUI
import ParallaxJellyfin

struct FocusRootView: View {
    @Environment(AppRouter.self) private var router
    @Environment(AppDependencies.self) private var deps
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
            let repo = await deps.libraryRepoFactory(session)
            // Load the sidebar's libraries and Home's feed concurrently, then reveal once both
            // settle — so the UI appears whole, with the hero already focusable.
            let vm = HomeViewModel(repo: repo)
            async let libs: [MediaCollection] = (try? await repo.collections()) ?? []
            async let homeLoaded: Void = vm.load()
            self.libraries = await libs
            _ = await homeLoaded
            self.session = session
            self.homeViewModel = vm
        }
    }

    private func tabView(session: Session, homeViewModel: HomeViewModel) -> some View {
        TabView(selection: $selectedTab) {
            Tab("Home", systemImage: "house", value: AppTab.home) {
                NavigationStack {
                    HomeView(preloaded: (session, homeViewModel))
                        .appScreenBackground()
                }
            }
            Tab("Library", systemImage: "rectangle.stack", value: AppTab.library) {
                NavigationStack {
                    LibraryHostView()
                        .appScreenBackground()
                }
            }
            Tab("Search", systemImage: "magnifyingglass", value: AppTab.search) {
                NavigationStack {
                    JellyfinSearchView()
                        .appScreenBackground()
                }
            }

            if !libraries.isEmpty {
                TabSection("Libraries") {
                    ForEach(libraries) { library in
                        Tab(library.name, systemImage: library.collectionType.symbolName, value: AppTab.collection(library.id)) {
                            NavigationStack {
                                JellyfinLibraryGridView(collection: library, session: session)
                                    .appScreenBackground()
                            }
                        }
                    }
                }
            }

            Tab("Settings", systemImage: "gearshape", value: AppTab.settings) {
                NavigationStack {
                    SettingsView()
                        .appScreenBackground()
                }
            }
        }
        .tabViewStyle(.sidebarAdaptable)
    }
}