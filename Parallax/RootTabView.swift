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
        case home, library, search
        /// A specific library surfaced directly in the sidebar's "Libraries" section.
        case collection(CollectionID)
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            Tab("Home", systemImage: "house", value: AppTab.home) {
                // Home keeps a transparent nav bar (see HomeView) so the account entry can
                // live in the toolbar like the other tabs, and so the pushed detail's back
                // button shares a bar to cross-fade with instead of sliding off on dismiss.
                NavigationStack { HomeView().toolbar { accountToolbar } }
            }
            Tab("Library", systemImage: "rectangle.stack", value: AppTab.library) {
                NavigationStack { LibraryHostView().toolbar { accountToolbar } }
            }
            Tab("Search", systemImage: "magnifyingglass", value: AppTab.search, role: .search) {
                NavigationStack { JellyfinSearchView().toolbar { accountToolbar } }
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
        .tabViewSidebarBottomBar { userFooter }
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

    // MARK: - Account entry (compact width)
    //
    // On iPad the sidebar footer opens settings; iPhone has no sidebar, so the primary
    // tabs carry an account button instead. Both just flip `router.presentingSettings`,
    // which RootView turns into the floating panel.

    /// Account button for the primary tabs (Home, Library, Search). Empty on regular
    /// width — the sidebar footer is the account entry there.
    @ToolbarContentBuilder
    private var accountToolbar: some ToolbarContent {
        if hSize == .compact, let session {
            ToolbarItem(placement: .topBarTrailing) {
                accountButton(session)
            }
            // The avatar is already a circle; the system's shared Liquid Glass capsule was
            // wrapping it into an oval "bordered" pill. Drop it so the avatar floats round.
            .sharedBackgroundVisibility(.hidden)
        }
    }

    private func accountButton(_ session: Session) -> some View {
        Button {
            router.presentingSettings = true
        } label: {
            AccountAvatar(session: session, size: 36)
        }
        .accessibilityLabel("Account and settings")
        .accessibilityHint("Opens settings")
    }

    // MARK: - Sidebar chrome

    /// Pinned account footer (avatar · name · server) — the design's sidebar foot.
    /// Tapping it opens the floating settings panel.
    @ViewBuilder
    private var userFooter: some View {
        if let session {
            let host = session.displayHost
            Button {
                router.presentingSettings = true
            } label: {
                HStack(spacing: Space.s12) {
                    AccountAvatar(session: session, size: 34)
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
                }
                // Aligns the footer under the sidebar tab-row glyphs. One shared knob
                // (`AppLayout.sidebarLeadingInset`) so every custom sidebar element keeps
                // the same left spacing as the rows — see AppLayout for why it's manual.
                .padding(.leading, AppLayout.sidebarLeadingInset)
                .padding(.trailing, Space.s12)
                .padding(.vertical, Space.s8)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            // Explicit label (replaces the children-derived one, which leaked the avatar
            // initial) + a hint that this opens settings.
            .accessibilityLabel("\(session.user.name), \(host)")
            .accessibilityHint("Opens settings")
        }
    }
}
