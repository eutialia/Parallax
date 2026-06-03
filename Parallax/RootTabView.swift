import SwiftUI
import ParallaxJellyfin

struct RootTabView: View {
    @Environment(AppRouter.self) private var router
    @Environment(PlaybackPresenter.self) private var playback
    @State private var selectedTab: AppTab = .home

    enum AppTab: Hashable {
        case home, library, search, servers
    }

    var body: some View {
        @Bindable var playback = playback
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
        // Remount every tab when the active server changes. `activeServerID`
        // is owned by AppRouter and updated by every site that switches, adds,
        // or signs out a server, so a switch from the Servers tab tears down
        // and rebuilds Home/Library/Search against the new server instead of
        // leaving them on the previous one's content.
        .id(router.activeServerID)
        .fullScreenCover(item: $playback.request) { request in
            PlayerView(itemID: request.itemID, session: request.session)
        }
    }
}
