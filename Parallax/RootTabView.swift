#if !os(tvOS)
import SwiftUI
import ParallaxJellyfin
import ParallaxCore

struct RootTabView: View {
    @Environment(AppRouter.self) private var router
    @Environment(AppDependencies.self) private var deps
    @Environment(\.horizontalSizeClass) private var hSize
    @Environment(\.colorScheme) private var colorScheme
    @State private var selectedTab: AppTab = .home
    @State private var session: Session?
    @State private var entries: [LibraryEntry] = []
    /// The last library opened from the sidebar's Libraries section (a server collection or
    /// the virtual Favorites grid), surfaced as the lone dynamic tab in the collapsed tab bar
    /// (Apple Music style). In-memory only: this `@State` resets on the `.id(activeServerID)`
    /// remount (server switch) and on relaunch — never persisted.
    @State private var lastVisitedLibraryTab: AppTab?

    var body: some View {
        tabView
        // Remount every tab when the active server changes. `activeServerID` is owned
        // by AppRouter and updated by every site that switches/adds/signs-out a server,
        // so a switch tears down + rebuilds the tabs (and reloads the sidebar libraries)
        // against the new server instead of leaving them on the previous one's content.
        .id(router.activeServerID)
        // Keyed on the reload token, not `activeServerID`: a server switch (token's id part)
        // AND an SMB add/remove (token's revision part) both rebuild `entries`. The `.id`
        // remount above stays on the session only, so a revision bump rebuilds the merged
        // list without tearing every tab down.
        .task(id: router.libraryReloadToken) {
            guard router.activeServerID != nil else { return }
            session = await deps.serverStore.active
            guard let session else { entries = []; return }
            entries = await MergedLibrary.entries(
                jellyfinSession: session,
                smbServers: await deps.serverStore.servers,
                repoFactory: deps.mediaRepoFactory
            )
        }
        // Tabs that exist at only one width — Library + Settings are compact-only (regular browses
        // libraries from the sidebar and hosts Settings in its footer), the per-library tabs are
        // regular-only. Crossing the size-class boundary (iPad Split View / Stage Manager resize)
        // removes the selected tab and would leave the selection dangling on a blank pane, so snap
        // back to one that exists at the new width.
        .onChange(of: hSize) { _, newValue in
            if newValue == .regular {
                if selectedTab == .settings || selectedTab == .library { selectedTab = .home }
            } else if isLibraryTab(selectedTab) {
                selectedTab = .library
            }
        }
    }

    /// Tab selection that records the last sidebar-opened library *in the same transaction* as the
    /// selection change. Updating `lastVisitedLibraryTab` here (rather than in a trailing
    /// `.onChange`) means the dynamic slot's tab-bar visibility flips in lockstep with selection —
    /// so the collapsed bar already contains the new library on the first frame of the sidebar→bar
    /// morph, instead of popping its layout a frame later (pills rendering small, then resizing).
    ///
    /// Don't "simplify" this to `$selectedTab` + `.onChange`: that was the original form and it
    /// produced exactly that visible pop on-device. `.onChange` is a post-update observer — it runs
    /// after the body pass that committed the selection, so its mutation lands a frame late. The
    /// binding setter runs *during* the selection write, coalescing both into one update.
    ///
    /// Only library tabs (`.collection` / `.favorites`) originate from the sidebar; the iPhone
    /// card-list drill-down is a NavigationStack push, never a tab switch, so it can't reach here.
    private var tabSelection: Binding<AppTab> {
        Binding(
            get: { selectedTab },
            set: { newValue in
                selectedTab = newValue
                if isLibraryTab(newValue) { lastVisitedLibraryTab = newValue }
            }
        )
    }

    /// Tabs that live in the sidebar's Libraries section (regular width only).
    private func isLibraryTab(_ tab: AppTab) -> Bool {
        if case .collection = tab { return true }
        return tab == .favorites
    }

    private var tabView: some View {
        TabView(selection: tabSelection) {
            Tab("Home", systemImage: "house", value: AppTab.home) {
                // Home keeps a transparent nav bar (see HomeView) so a pushed detail's back
                // button shares a bar to cross-fade with instead of sliding off on dismiss.
                NavigationStack {
                    HomeView()
                }
            }
            // iPhone only: the card-list browser. On iPad the sidebar's per-library tabs (below)
            // ARE the browser — selecting a library drills straight to its grid — so there's no
            // separate Library tab to duplicate that, and no list to push a drill-down from.
            if hSize == .compact {
                Tab("Library", systemImage: "rectangle.stack", value: AppTab.library) {
                    NavigationStack {
                        LibraryHostView()
                    }
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
                }
            }

            // iPhone only: Settings rides the bottom tab bar — there's no sidebar to host the
            // footer entry iPad uses. It's an inline tab in its own NavigationStack; iPad instead
            // opens the modal sheet from `RootView` via its sidebar footer.
            if hSize == .compact {
                Tab("Settings", systemImage: "gearshape", value: AppTab.settings) {
                    NavigationStack {
                        SettingsView()
                    }
                }
            }

            // iPad regular only: the libraries as a grouped, titled sidebar section. The section
            // header earns its keep for the multi-source future (each Jellyfin / SMB server becomes
            // its own section). Each library drills straight to its grid.
            //
            // Collapsed tab bar: the SECTION is hidden from the bar (`.defaultVisibility` below) so
            // its "Libraries" header doesn't render there — per-tab hiding alone left the empty
            // header behind as a stray pill. The last-opened library then overrides that hiding to
            // appear as the lone dynamic slot to the right of Search; nothing shows before any
            // library is opened (`lastVisitedLibraryID` starts nil). The expanded sidebar ignores
            // `.tabBar` visibility and lists every library under the header.
            if hSize == .regular, let session, !entries.isEmpty {
                // TODO: per-server sections — one `TabSection` per source (each Jellyfin /
                // SMB server its own titled group), instead of this single merged section.
                // Deferred UI polish; the merge already tags every entry by source.
                TabSection("Libraries") {
                    ForEach(entries) { entry in
                        Tab(entry.collection.name, systemImage: entry.collection.collectionType.symbolName, value: AppTab.collection(entry.id)) {
                            NavigationStack {
                                // Title is owned by the grid (from the collection) so the iPhone
                                // Library-list drill-down and this direct tab show it identically.
                                LibraryGridView(collection: entry.collection, source: entry.source)
                            }
                        }
                        .defaultVisibility(AppTab.collection(entry.id) == lastVisitedLibraryTab ? .visible : .hidden, for: .tabBar)
                    }
                    // The virtual cross-library Favorites grid — movies + shows the user
                    // favorited, every server library merged. Rides the same dynamic
                    // collapsed-bar slot as the real libraries.
                    Tab("Favorites", systemImage: "heart", value: AppTab.favorites) {
                        NavigationStack {
                            LibraryGridView(scope: .favorites, title: "Favorites", session: session)
                        }
                    }
                    .defaultVisibility(lastVisitedLibraryTab == .favorites ? .visible : .hidden, for: .tabBar)
                }
                .defaultVisibility(.hidden, for: .tabBar)
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        // The screen floor is a single `Color.background` behind the whole tab host (see
        // `RootView`); tabs no longer paint their own. The sidebar / bottom-bar glass now tints
        // from that floor and reads as a solid bar — fine, there's only a flat color to refract.
        // The one hand-styled chrome row is `settingsFooter` below: its label color is picked to
        // match the system tab rows on this floor.
        .tabViewSidebarBottomBar { settingsFooter }
        .environment(\.appIdiom, hSize == .regular ? .regular : .compact)
    }

    // MARK: - Settings entry
    //
    // iPad: pinned below the tab list via `tabViewSidebarBottomBar` (not mixed in with
    // Home / Library / Search), opening the modal sheet. iPhone: a tab on the bottom bar
    // (added in `tabView`) — no sidebar to host a footer.

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
#endif
