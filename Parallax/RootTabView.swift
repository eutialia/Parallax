import SwiftUI
import ParallaxJellyfin

struct RootTabView: View {
    @Environment(AppRouter.self) private var router
    @Environment(AppDependencies.self) private var deps
    @Environment(\.horizontalSizeClass) private var hSize
    @Environment(\.colorScheme) private var colorScheme
    @State private var selectedTab: AppTab = .home
    @State private var session: Session?
    @State private var libraries: [MediaCollection] = []

    enum AppTab: Hashable {
        case home, library, search
        /// A specific library surfaced directly in the sidebar's "Libraries" section.
        case collection(CollectionID)
    }

    var body: some View {
        tabView
        // Remount every tab when the active server changes. `activeServerID` is owned
        // by AppRouter and updated by every site that switches/adds/signs-out a server,
        // so a switch tears down + rebuilds the tabs (and reloads the sidebar libraries)
        // against the new server instead of leaving them on the previous one's content.
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
                // Home keeps a transparent nav bar (see HomeView) so the settings button can
                // live in the toolbar like the other tabs, and so the pushed detail's back
                // button shares a bar to cross-fade with instead of sliding off on dismiss.
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
            // Deliberately NOT `role: .search`, and JellyfinSearchView uses its own
            // in-content SearchBar rather than `.searchable`. In iPadOS 26 the system
            // search field (role-search tab or `.searchable`) gets hoisted into the
            // top-trailing Liquid Glass slot on focus, reflows the layout, and lets the
            // search presentation seize the sidebar toggle (it flips to "Hide Sidebar"
            // while the keyboard is up). A plain tab + custom field sidesteps all of it.
            Tab("Search", systemImage: "magnifyingglass", value: AppTab.search) {
                NavigationStack {
                    JellyfinSearchView()
                        .toolbar { settingsToolbar }
                        .appScreenBackground()
                }
            }

            // The user's actual libraries, as a titled sidebar section (the design's
            // "Libraries" group) — each drills straight to its grid. Sidebar only:
            // gated to regular width so the compact tab bar (iPhone / split view)
            // keeps its primary tabs instead of spilling every library into it.
            if hSize == .regular, let session, !libraries.isEmpty {
                TabSection("Libraries") {
                    ForEach(libraries) { library in
                        Tab(library.name, systemImage: library.collectionType.symbolName, value: AppTab.collection(library.id)) {
                            NavigationStack {
                                // Title is owned by the grid (from the collection) so
                                // this matches the Library-list drill-down exactly.
                                JellyfinLibraryGridView(collection: library, session: session)
                                    .appScreenBackground()
                            }
                        }
                        // Sidebar-only: don't also crowd the collapsed top tab bar with
                        // every library — they're a sidebar convenience (the Library tab
                        // remains the primary browse-all entry).
                        .defaultVisibility(.hidden, for: .tabBar)
                    }
                }
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        // Matinee lives on tab *content* only (`.appScreenBackground()` inside each stack).
        // Tab chrome — iPad sidebar, bottom bar, and `tabViewSidebarBottomBar` — keeps the
        // system's Liquid Glass so hierarchical label styles match native tab rows.
        .tabViewSidebarBottomBar { settingsFooter }
    }

    // MARK: - Settings entry
    //
    // iPad: pinned below the tab list via `tabViewSidebarBottomBar` (not mixed in with
    // Home / Library / Search). iPhone: nav-bar button — no sidebar to host a footer.

    /// Settings for the primary tabs (Home, Library, Search). Empty on regular width —
    /// the sidebar bottom bar is the settings entry there.
    @ToolbarContentBuilder
    private var settingsToolbar: some ToolbarContent {
        if hSize == .compact {
            ToolbarItem(placement: .topBarTrailing) {
                settingsButton
            }
        }
    }

    private var settingsButton: some View {
        Button(action: openSettings) {
            Image(systemName: "gearshape")
        }
        .accessibilityLabel("Settings")
    }

    // MARK: - Sidebar chrome

    /// Pinned settings row at the bottom of the iPad sidebar — separate from the tab
    /// list above. Dark mode uses hierarchical styles to match native rows on glass; light
    /// mode uses Matinee tokens because hierarchical `.primary` washes out on the light
    /// sidebar material.
    private var settingsFooter: some View {
        Button(action: openSettings) {
            Label("Settings", systemImage: "gearshape")
                .font(.body)
                .foregroundStyle(sidebarChromeLabel)
                .frame(maxWidth: .infinity, alignment: .leading)
                // Aligns under the sidebar tab-row glyphs — see AppLayout.
                .padding(.leading, AppLayout.sidebarLeadingInset)
                .padding(.trailing, Space.s12)
                .padding(.vertical, Space.s8)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens settings")
    }

    private var sidebarChromeLabel: AnyShapeStyle {
        colorScheme == .dark ? AnyShapeStyle(.primary) : AnyShapeStyle(Color.label)
    }

    private func openSettings() {
        router.presentingSettings = true
    }
}
