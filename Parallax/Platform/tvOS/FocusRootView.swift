import SwiftUI
import ParallaxJellyfin

struct FocusRootView: View {
    @Environment(AppRouter.self) private var router
    @Environment(AppDependencies.self) private var deps
    @State private var selectedTab: AppTab = .home
    @State private var session: Session?
    @State private var libraries: [MediaCollection] = []

    var body: some View {
        tabView
            .environment(\.appIdiom, .tv)
            .id(router.activeServerID)
            .onChange(of: router.presentingSettings) { _, presenting in
                guard presenting else { return }
                selectedTab = .settings
                router.presentingSettings = false
            }
            .task(id: router.activeServerID) {
                guard router.activeServerID != nil else { return }
                session = await deps.serverStore.active
                guard let session else { libraries = []; return }
                let repo = await deps.libraryRepoFactory(session)
                libraries = (try? await repo.collections()) ?? []
            }
    }

    private var tabView: some View {
        TabView(selection: $selectedTab) {
            Tab("Home", systemImage: "house", value: AppTab.home) {
                NavigationStack {
                    HomeView()
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

            if let session, !libraries.isEmpty {
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