#if !os(tvOS)
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
        // Some tabs only exist at one width — Settings is compact-only (regular hosts it in the
        // sidebar footer), the Libraries section is regular-only. Crossing the size-class boundary
        // (iPad Split View / Stage Manager resize) removes the selected tab and would leave the
        // selection dangling on a blank pane, so snap back to one that exists at the new width.
        .onChange(of: hSize) { _, newValue in
            if newValue == .regular, selectedTab == .settings {
                selectedTab = .home
            } else if newValue == .compact, case .collection = selectedTab {
                selectedTab = .library
            }
        }
    }

    private var tabView: some View {
        TabView(selection: $selectedTab) {
            Tab("Home", systemImage: "house", value: AppTab.home) {
                // Home keeps a transparent nav bar (see HomeView) so a pushed detail's back
                // button shares a bar to cross-fade with instead of sliding off on dismiss.
                NavigationStack {
                    HomeView()
                }
            }
            Tab("Library", systemImage: "rectangle.stack", value: AppTab.library) {
                NavigationStack {
                    LibraryHostView()
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
