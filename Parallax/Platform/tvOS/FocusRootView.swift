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
                        .toolbar { settingsToolbar }
                        .appScreenBackground()
                }
            }
            Tab("Library", systemImage: "rectangle.stack", value: AppTab.library) {
                NavigationStack {
                    LibraryHostView()
                        .toolbar { settingsToolbar }
                        .appScreenBackground()
                }
            }
            Tab("Search", systemImage: "magnifyingglass", value: AppTab.search) {
                NavigationStack {
                    JellyfinSearchView()
                        .toolbar { settingsToolbar }
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
        }
        .tabViewStyle(.sidebarAdaptable)
    }

    @ToolbarContentBuilder
    private var settingsToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            settingsButton
        }
    }

    private var settingsButton: some View {
        Button(action: openSettings) {
            Image(systemName: "gearshape")
        }
        .accessibilityLabel("Settings")
    }

    private func openSettings() {
        router.presentingSettings = true
    }
}