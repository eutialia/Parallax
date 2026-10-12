import SwiftUI
import ParallaxJellyfin
import ParallaxCore
import ParallaxFeatures

struct FocusRootView: View {
    @Environment(AppModel.self) private var app
    @Environment(AppRouter.self) private var router
    @State private var selectedTab: AppTab = .home
    /// Flips true once the first `loadSources()` pass settles — the readiness signal that reveals
    /// the tab host. `@State`, so the `.id(activeServerID)` remount on a Jellyfin switch resets it.
    @State private var isReady = false

    /// One group per configured source, in server add order — the sidebar's titled sections.
    private var groups: [LibraryGroup] { app.libraries.groups }

    /// Reveal once the loads settle, or sooner when Home already has something focusable — a feed
    /// hydrated from the cache. Showing the `.sidebarAdaptable` TabView with nothing to focus is
    /// the failure this gate exists to prevent.
    private var showsTabs: Bool {
        isReady || app.home?.state == .loaded
    }

    var body: some View {
        Group {
            // Gate the sidebar+content behind a full-screen launch surface until the first library
            // load settles — the structural fix for the menu owning focus during the cold-launch
            // fetch. The `.sidebarAdaptable` menu can only relinquish focus to content that has a
            // focusable view; while Home is a skeleton it has none, so the menu stays focused and
            // expanded. Withholding the TabView until the data is in hand sidesteps that (matches the
            // Apple TV app's spinner-then-everything-together launch). For an SMB-only config Home is
            // the (non-focusable) "no feed" placeholder, so the sidebar lands focus expanded on the
            // libraries — the correct entry point when there's no Jellyfin hero to focus.
            if showsTabs {
                tabView
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
        #if DEBUG
        // Land on the Settings tab from a bare `simctl launch` — Home's hero carousel swallows
        // directional input, so scripted UI verification can't reach the sidebar reliably.
        .task {
            guard ProcessInfo.processInfo.arguments.contains("-openSettingsTab") else { return }
            selectedTab = .settings
        }
        // Same idea for the library tabs (`-openSMBTab` / `-openJellyfinTab`, first entry of that
        // source wins): scripted verification of the browse walls needs to land there without
        // driving the hero + sidebar by key events. Two triggers, both needed: `showsTabs` covers
        // the cold path (entries commit BEFORE the reveal), and `groups` covers the cache-reveal
        // path — a hydrated Home feed reveals the tabs with NO groups yet, and the entries land a
        // moment later. One-shot via the tab check so later library reloads don't yank the selection.
        .onChange(of: showsTabs) { _, _ in jumpToRequestedLibraryTab() }
        .onChange(of: groups) { _, _ in jumpToRequestedLibraryTab() }
        #endif
        // If the selected library tab's backing entry just vanished, snap to Home so the tab host
        // isn't left on a gone tab (shared with RootTabView via `snappedIfStale`).
        .onChange(of: groups) { _, groups in selectedTab = selectedTab.snappedIfStale(against: groups.allEntries) }
        // Keyed on the reload token (server switch + SMB add/remove), matching RootTabView.
        // The `.id(activeServerID)` remount above stays session-only.
        .task(id: router.libraryReloadToken) {
            // Bail only while there's NO source at all (the transient bootstrapping window); the
            // token re-fires once a source resolves. An SMB-only config passes here.
            guard router.hasAnySource else { return }
            // The sidebar's libraries and Home's feed load together, so the UI appears whole, with
            // the hero (if any) already focusable. The launch hold releases inside.
            await app.loadSources()
            guard !Task.isCancelled else { return }
            isReady = true
        }
    }

    #if DEBUG
    /// Body of the `-openSMBTab` / `-openJellyfinTab` launch-arg jump — see the `.onChange` pair
    /// in `body`. One-shot: only fires while the selection still sits on the launch default, so
    /// the library reloads that also move `groups` can't yank the user's later navigation.
    private func jumpToRequestedLibraryTab() {
        guard selectedTab == .home else { return }
        let args = ProcessInfo.processInfo.arguments
        let wantsSMB = args.contains("-openSMBTab")
        let wantsJellyfin = args.contains("-openJellyfinTab")
        guard wantsSMB || wantsJellyfin else { return }
        for entry in groups.allEntries {
            switch entry.source {
            case .smb where wantsSMB, .jellyfin where wantsJellyfin:
                selectedTab = .collection(entry.id)
                return
            default:
                continue
            }
        }
    }
    #endif

    /// One library row in a server's sidebar section. Extracted with an EXPLICIT
    /// `some TabContent<AppTab>` return type, and not inlined, for two reasons that bit here:
    /// the annotation pins `TabValue` to non-optional `AppTab` (left to infer inside two nested
    /// `ForEach`es, `TabSection` resolves to its optional-selection overload and the whole
    /// `TabContentBuilder` stops matching), and pulling the `NavigationStack` + destination out of
    /// the doubly-nested builder keeps the remaining expression under the type-checker's limit.
    /// Without it the roots fail as `TabView` silently falls back to its legacy `ViewBuilder`
    /// overload and reports "Tab … does not conform to 'View'" against the FIRST tab in the file.
    private func libraryTab(for entry: LibraryEntry) -> some TabContent<AppTab> {
        Tab(entry.collection.name, systemImage: entry.tabSymbolName, value: AppTab.collection(entry.id)) {
            NavigationStack {
                // SMB shares drill into the folder browser; Jellyfin collections into the poster
                // grid (shared with the iPhone list — one dispatch site).
                libraryEntryDestination(for: entry)
            }
        }
    }

    private var tabView: some View {
        TabView(selection: $selectedTab) {
            Tab("Home", systemImage: "house", value: AppTab.home) {
                NavigationStack {
                    HomeView()
                }
            }
            // Search is Jellyfin-backed (SMB has no search index) — omitted in an SMB-only config
            // rather than shown as a permanently-empty tab. `role: .search` = the system search
            // tab; JellyfinSearchView's `.searchable` renders the HIG search screen inside it.
            // (A TabView-level `.searchable` pairing was tried and reverted 2026-08-10 —
            // owner-rejected; see JellyfinSearchView.)
            if router.hasSearchableSource {
                Tab(value: AppTab.search, role: .search) {
                    NavigationStack {
                        JellyfinSearchView(app: app)
                    }
                }
            }

            // No "Library" tab on tvOS: the sidebar's Libraries section IS the browser — each entry
            // drills straight to its grid. With no list to push a drill-down from, the selected
            // library tab's own label drives the collapsed sidebar's top-left name (the old
            // drill-down path showed a stale "Library" there).
            // Favorites is a cross-SERVER virtual library, so it sits at top level rather than
            // inside a server's section (which would claim it belongs to that server). Jellyfin
            // concept — omitted SMB-only. Mirrors RootTabView's placement.
            if app.libraries.hasJellyfinSource {
                Tab("Favorites", systemImage: "heart", value: AppTab.favorites) {
                    NavigationStack {
                        FavoritesView()
                    }
                }
            }

            // One collapsible section per server, in the order the user added them — libraries are
            // never merged across servers, so two servers that both expose "Movies" stay two rows
            // under two headers. A single configured source keeps the plain "Libraries" title.
            ForEach(groups) { group in
                TabSection(groups.sectionTitle(for: group)) {
                    ForEach(group.entries) { libraryTab(for: $0) }
                }
            }

            Tab("Settings", systemImage: "gearshape", value: AppTab.settings) {
                NavigationStack {
                    SettingsView()
                }
            }
        }
        .tabViewStyle(.sidebarAdaptable)
    }
}