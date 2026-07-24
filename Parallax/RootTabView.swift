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
    /// True while a Jellyfin session is active but its `collections()` fetch failed — the sidebar is
    /// showing SMB-only (or nothing) because the network is down, not because the server has no
    /// libraries. Gates `.recoversFromOffline` so the libraries repopulate when connectivity returns;
    /// SMB entries, being local, are unaffected. Mirrors the content views' `isStalled`.
    @State private var librariesStalled = false
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
        .task(id: router.libraryReloadToken) { await loadLibraries() }
        // Repopulate the sidebar's Jellyfin libraries when the network returns (or the app
        // foregrounds online) after a launch that couldn't reach the server. Gated on
        // `librariesStalled`, so a healthy list — and the local SMB shares — are never re-pulled. The
        // reload token (above) doesn't move on a reconnect, so without this the libraries stayed gone
        // until a server switch. Event-based — no pull-to-refresh.
        .recoversFromOffline(isStalled: librariesStalled) { await loadLibraries() }
        // Tabs that exist at only one layout — Library + Settings are compact-only (sidebar
        // layouts browse libraries from the sidebar and host Settings in its footer), the
        // per-library tabs are sidebar-only. Crossing the layout boundary (iPad Split View /
        // Stage Manager resize — iPhone never crosses, see `isSidebarLayout`) removes the
        // selected tab and would leave the selection dangling on a blank pane, so snap back
        // to one that exists in the new layout.
        .onChange(of: isSidebarLayout) { _, isSidebar in
            if isSidebar {
                if selectedTab == .settings || selectedTab == .library { selectedTab = .home }
            } else if isLibraryTab(selectedTab) {
                selectedTab = .library
            }
        }
    }

    /// Sidebar (iPad-regular) vs compact tab structure. Deliberately DEVICE-gated, not pure
    /// size class: a Pro Max iPhone reports `.regular` width in landscape, and keying the tab
    /// STRUCTURE on size class there tears down whole `Tab`/`NavigationStack` subtrees on every
    /// rotation — a landscape playback session silently swapped the tree under the player, so
    /// dismissing landed on Home with the Library drill-in and scroll position gone. iPhone
    /// therefore always keeps the compact structure (same principle as
    /// `PlayerControlsView.isPad`); iPad keeps following its real size class so Split View /
    /// Stage Manager still adapt.
    private var isSidebarLayout: Bool {
        UIDevice.current.userInterfaceIdiom == .pad && hSize == .regular
    }

    /// Resolve + commit the sidebar's merged library list. Shared by the launch `.task` and offline
    /// recovery so the two never drift. `active` may be nil in an SMB-only config — `MergedLibrary`
    /// builds the SMB entries either way; a nil session just contributes no Jellyfin collections.
    /// Captures into locals across the awaits, then commits under a cancellation check: a token
    /// change cancels the launch task and starts a fresh one, and a now-stale snapshot must not
    /// clobber the newer state (or snap selection off a tab that's still valid in the latest entries).
    private func loadLibraries() async {
        guard router.hasAnySource else { entries = []; session = nil; librariesStalled = false; return }
        let active = await deps.serverStore.active
        var hiddenJellyfin: Set<String> = []
        if let active { hiddenJellyfin = await deps.serverStore.hiddenCollectionIDs(for: active.id) }
        let outcome = await MergedLibrary.resolve(
            jellyfinSession: active,
            smbServers: await deps.serverStore.servers,
            hiddenJellyfinCollectionIDs: hiddenJellyfin,
            jellyfinRepo: deps.mediaRepoFactory
        )
        guard !Task.isCancelled else { return }
        session = active
        entries = outcome.entries
        librariesStalled = outcome.jellyfinCollectionsFailed
        // If the selected library tab's backing entry just vanished, snap to Home so the detail
        // pane isn't left on a gone tab (shared with FocusRootView via `snappedIfStale`).
        selectedTab = selectedTab.snappedIfStale(against: outcome.entries)
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
            if !isSidebarLayout {
                Tab("Library", systemImage: "rectangle.stack", value: AppTab.library) {
                    NavigationStack {
                        LibraryHostView()
                    }
                }
            }
            // Search is Jellyfin-backed (SMB has no search index), so it's hidden in an
            // SMB-only config rather than shown as a permanently-empty tab.
            //
            // `role: .search` + `.searchable` inside JellyfinSearchView = the system
            // search-tab pattern: the separated magnifier pill in the bar, the field
            // hosted in the chrome via the DRAWER placement (the wide bar stacked below
            // the nav bar, like the TV app — see JellyfinSearchView; the default
            // placement rendered a top-trailing corner field instead). Living in the
            // chrome keeps the field out of the keyboard-avoidance path entirely — the
            // old in-content custom bar got translated off-screen by the keyboard under
            // the TabView's hosting.
            if router.activeServerID != nil {
                Tab(value: AppTab.search, role: .search) {
                    NavigationStack {
                        JellyfinSearchView()
                    }
                }
            }

            // iPhone only: Settings rides the bottom tab bar — there's no sidebar to host the
            // footer entry iPad uses. It's an inline tab in its own NavigationStack; iPad instead
            // opens the modal sheet from `RootView` via its sidebar footer.
            if !isSidebarLayout {
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
            if isSidebarLayout, !entries.isEmpty {
                // TODO: per-server sections — one `TabSection` per source (each Jellyfin /
                // SMB server its own titled group), instead of this single merged section.
                // Deferred UI polish; the merge already tags every entry by source.
                TabSection("Libraries") {
                    ForEach(entries) { entry in
                        Tab(entry.collection.name, systemImage: entry.tabSymbolName, value: AppTab.collection(entry.id)) {
                            NavigationStack {
                                // SMB shares drill into the folder browser; Jellyfin collections into
                                // the poster grid (shared with the iPhone list — one dispatch site).
                                libraryEntryDestination(for: entry)
                            }
                        }
                        .defaultVisibility(AppTab.collection(entry.id) == lastVisitedLibraryTab ? .visible : .hidden, for: .tabBar)
                    }
                    // The virtual cross-library Favorites grid — movies + shows the user
                    // favorited, every server library merged. Rides the same dynamic
                    // collapsed-bar slot as the real libraries. Jellyfin-only: favorites are a
                    // Jellyfin concept, so an SMB-only config (nil session) omits it.
                    if let session {
                        Tab("Favorites", systemImage: "heart", value: AppTab.favorites) {
                            NavigationStack {
                                LibraryGridView(scope: .favorites, title: "Favorites", session: session)
                            }
                        }
                        .defaultVisibility(lastVisitedLibraryTab == .favorites ? .visible : .hidden, for: .tabBar)
                    }
                }
                .defaultVisibility(.hidden, for: .tabBar)
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        // The screen floor is a single `BackgroundField` behind the whole tab host (see
        // `RootView`); tabs no longer paint their own. The sidebar / bottom-bar glass now tints
        // from that floor and reads as a solid bar — fine: the field is locally near-flat
        // (±3–4% L across the whole screen), so there's nothing sharp to refract.
        // The one hand-styled chrome row is `settingsFooter` below: its label color is picked to
        // match the system tab rows on this floor.
        .tabViewSidebarBottomBar { settingsFooter }
        // Pinned to the same device-gated predicate as the tab structure: a Pro Max in
        // landscape must not flip downstream `appIdiom` layout branches to iPad forms
        // while the tab tree stays in its compact shape.
        .environment(\.appIdiom, isSidebarLayout ? .regular : .compact)
    }

    // MARK: - Settings entry
    //
    // iPad: pinned below the tab list via `tabViewSidebarBottomBar` (not mixed in with
    // Home / Library / Search), opening the modal sheet. iPhone: a tab on the bottom bar
    // (added in `tabView`) — no sidebar to host a footer.

    // MARK: - Sidebar chrome

    /// Pinned settings row at the bottom of the iPad sidebar — separate from the tab
    /// list above. Dark mode uses hierarchical styles to match native rows on glass; light
    /// mode uses the light-face tokens because hierarchical `.primary` washes out on the light
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

#if DEBUG
/// Sidebar library-tab labels, the way `TabSection("Libraries")` renders them: a Jellyfin
/// collection takes its media-type glyph, an SMB share the network-share glyph (`tabSymbolName`).
/// The point is to confirm an SMB share reads as a NETWORK SHARE next to the Jellyfin rows — and to
/// compare glyph candidates side by side so the clearest one wins (the task started on
/// `externaldrive.connected.to.line.below`). Mirrors RootView's app-wide `Color.label` tint so the
/// resting glyph color matches the real sidebar.
private struct SMBSidebarTabGlyphPreview: View {
    private let smbEntry = LibraryEntry(
        source: .smb(SMBServerRef(id: ServerID(rawValue: "preview"), data: SMBServerData(host: "nas.local", username: "guest", domain: "", shares: ["Media"]))),
        collection: MediaCollection(id: CollectionID(rawValue: "Media"), name: "Media", collectionType: .movies, primaryTag: nil)
    )

    private func tabRowLabel(_ title: String, _ symbol: String) -> some View {
        Label(title, systemImage: symbol)
            .font(.body)
            .labelStyle(.titleAndIcon)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Space.s16)
            .padding(.vertical, Space.s12)
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(Color.secondaryLabel)
            .padding(.horizontal, Space.s16)
            .padding(.bottom, Space.s8)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader("LIBRARIES")
            // The real mix: two Jellyfin libraries + the SMB share, each via its own glyph rule.
            tabRowLabel("Movies", CollectionType.movies.symbolName)
            tabRowLabel("Shows", CollectionType.tvShows.symbolName)
            tabRowLabel(smbEntry.collection.name, smbEntry.tabSymbolName)

            Divider().padding(.vertical, Space.s12)

            sectionHeader("SMB GLYPH CANDIDATES")
            tabRowLabel("connected.to.line.below", "externaldrive.connected.to.line.below")
            tabRowLabel("badge.wifi", "externaldrive.badge.wifi")
            tabRowLabel("network", "network")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.vertical, Space.s26)
        .screenFloor()
        .tint(Color.label)
    }
}

#Preview("SMB sidebar tab glyph", traits: .fixedLayout(width: 360, height: 460)) {
    SMBSidebarTabGlyphPreview()
}
#endif
#endif
