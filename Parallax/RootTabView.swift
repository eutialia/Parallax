import SwiftUI
import ParallaxJellyfin

struct RootTabView: View {
    @Environment(AppRouter.self) private var router
    @Environment(AppDependencies.self) private var deps
    @Environment(\.horizontalSizeClass) private var hSize
    @State private var selectedTab: AppTab = .home
    @State private var session: Session?
    @State private var libraries: [MediaCollection] = []

    enum AppTab: Hashable {
        case home, library, search, servers
        /// A specific library surfaced directly in the sidebar's "Libraries" section.
        case collection(CollectionID)
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

            // The user's actual libraries, as a titled sidebar section (the design's
            // "Libraries" group) — each drills straight to its grid. Sidebar only:
            // gated to regular width so the compact tab bar (iPhone / split view)
            // keeps its four primary tabs instead of spilling every library into it.
            if hSize == .regular, let session, !libraries.isEmpty {
                TabSection("Libraries") {
                    ForEach(libraries) { library in
                        Tab(library.name, systemImage: icon(for: library.collectionType), value: AppTab.collection(library.id)) {
                            NavigationStack {
                                JellyfinLibraryGridView(collectionID: library.id, session: session)
                                    .navigationTitle(library.name)
                            }
                        }
                        // Sidebar-only: don't also crowd the collapsed top tab bar with
                        // every library — they're a sidebar convenience (the Library tab
                        // remains the primary browse-all entry).
                        .defaultVisibility(.hidden, for: .tabBar)
                    }
                }
            }

            Tab("Servers", systemImage: "server.rack", value: AppTab.servers) {
                NavigationStack { ServerListView() }
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        .tabViewSidebarHeader { brand }
        .tabViewSidebarBottomBar { userFooter }
        // Remount every tab when the active server changes. `activeServerID` is owned
        // by AppRouter and updated by every site that switches/adds/signs-out a server,
        // so a switch tears down + rebuilds the tabs (and reloads the sidebar libraries)
        // against the new server instead of leaving them on the previous one's content.
        .id(router.activeServerID)
        .task {
            session = await deps.serverStore.active
            guard let session else { libraries = []; return }
            let repo = await deps.libraryRepoFactory(session)
            libraries = (try? await repo.collections()) ?? []
        }
    }

    // MARK: - Sidebar chrome

    private var brand: some View {
        HStack(spacing: Space.s12) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.label)
                .frame(width: 30, height: 30)
                .overlay {
                    Image(systemName: "hexagon.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.background)
                }
            Text("Parallax")
                .font(.title3.weight(.bold))
                .foregroundStyle(Color.label)
            Spacer(minLength: 0)
        }
        .padding(.vertical, Space.s8)
    }

    /// Pinned account footer (avatar · name · server) — the design's sidebar foot.
    @ViewBuilder
    private var userFooter: some View {
        if let session {
            HStack(spacing: Space.s12) {
                Circle()
                    .fill(Color.fill)
                    .frame(width: 34, height: 34)
                    .overlay {
                        Text(initial(session.user.name))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.label)
                    }
                VStack(alignment: .leading, spacing: 1) {
                    Text(session.user.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.label)
                        .lineLimit(1)
                    Text(session.serverURL.host() ?? session.serverName)
                        .font(.caption)
                        .foregroundStyle(Color.secondaryLabel)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, Space.s8)
        }
    }

    private func initial(_ name: String) -> String {
        guard let first = name.first else { return "?" }
        return String(first).uppercased()
    }

    /// SF Symbol for a library, by Jellyfin collection type.
    private func icon(for type: CollectionType) -> String {
        switch type {
        case .movies: return "film"
        case .tvShows: return "tv"
        case .other(let raw):
            let kind = raw.lowercased()
            if kind.contains("music") { return "music.note" }
            if kind.contains("book") { return "books.vertical" }
            if kind.contains("photo") || kind.contains("home") { return "photo" }
            return "rectangle.stack"
        }
    }
}
