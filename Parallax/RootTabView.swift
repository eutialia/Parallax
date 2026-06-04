import SwiftUI
import ParallaxJellyfin

struct RootTabView: View {
    @Environment(AppRouter.self) private var router
    @Environment(AppDependencies.self) private var deps
    @Environment(\.horizontalSizeClass) private var hSize
    @State private var selectedTab: AppTab = .home
    @State private var session: Session?
    @State private var libraries: [MediaCollection] = []
    /// Navigation path for the Servers tab's stack. Owned here (not inside
    /// `ServerListView`) so the sidebar account footer — which lives in the tab-view
    /// chrome, outside every per-tab `NavigationStack` — can push a server's settings
    /// page by switching to the Servers tab and setting this path.
    @State private var serversPath: [Session] = []

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
                                // Title is owned by the grid (from the collection) so
                                // this matches the Library-list drill-down exactly.
                                JellyfinLibraryGridView(collection: library, session: session)
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
                NavigationStack(path: $serversPath) { ServerListView() }
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
        // The header is the first row BELOW the system sidebar collapse toggle — the
        // toggle owns the nav-bar band and `tabViewSidebarHeader` content can't enter
        // it (no public API on a `.sidebarAdaptable` sidebar; only NavigationSplitView
        // exposes that toolbar, which the project forbids as a root). Inset the leading
        // edge to line up with the tab-row labels and give it room to read as a
        // deliberate brand row rather than a cell jammed under the toggle.
        .padding(.horizontal, Space.s12)
        .padding(.top, Space.s8)
        .padding(.bottom, Space.s12)
    }

    /// Pinned account footer (avatar · name · server) — the design's sidebar foot.
    /// Tapping it opens this server's settings page.
    @ViewBuilder
    private var userFooter: some View {
        if let session {
            let host = session.serverURL.host() ?? session.serverName
            Button {
                // The footer lives in the tab-view chrome, outside the per-tab stacks,
                // so navigate by switching to the Servers tab and pushing the settings
                // page onto its path directly.
                selectedTab = .servers
                serversPath = [session]
            } label: {
                HStack(spacing: Space.s12) {
                    Circle()
                        .fill(Color.fill)
                        .frame(width: 34, height: 34)
                        .overlay {
                            Text(initial(session.user.name))
                                // Fixed so the initial stays inside the 34pt circle at
                                // large Dynamic Type sizes.
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(Color.label)
                        }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(session.user.name)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.label)
                            .lineLimit(1)
                        Text(host)
                            .font(.caption)
                            .foregroundStyle(Color.secondaryLabel)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .scaledFont(13, relativeTo: .footnote, weight: .semibold)
                        .foregroundStyle(Color.tertiaryLabel)
                }
                // Inset to align the avatar's leading edge with the sidebar tab-row
                // labels (the system insets the row pills; the bottom-bar closure is
                // handed the full sidebar width, so without this it butts the glass edge).
                .padding(.horizontal, Space.s12)
                .padding(.vertical, Space.s8)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            // Explicit label (replaces the children-derived one, which leaked the avatar
            // initial) + a hint, since the chevron is the only sighted "opens settings" cue.
            .accessibilityLabel("\(session.user.name), \(host)")
            .accessibilityHint("Opens server settings")
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
