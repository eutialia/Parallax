import SwiftUI
import ParallaxJellyfin

struct RootTabView: View {
    @Environment(AppDependencies.self) private var deps
    @State private var selectedTab: AppTab = .home
    @State private var activeServerID: ServerID?

    enum AppTab: Hashable {
        case home, library, search, servers
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            Tab("Home", systemImage: "house", value: AppTab.home) {
                NavigationStack { HomeView() }
            }
            Tab("Library", systemImage: "rectangle.stack", value: AppTab.library) {
                NavigationStack { LibraryHostView() }
            }
            Tab("Search", systemImage: "magnifyingglass", value: AppTab.search, role: .search) {
                NavigationStack { JellyfinSearchView() }
            }
            Tab("Servers", systemImage: "server.rack", value: AppTab.servers) {
                NavigationStack { ServerListView() }
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        .id(activeServerID)
        .task(id: activeServerID) {
            // Re-read on appearance and whenever activeServerID changes.
            // First-launch: activeServerID is nil → reads the actual active
            // and sets it, triggering one more task pass that's a no-op.
            let current = await deps.serverStore.active?.id
            if current != activeServerID {
                activeServerID = current
            }
        }
    }
}
