import SwiftUI
import ParallaxJellyfin
import ParallaxCore

struct JellyfinSearchView: View {
    @Environment(AppDependencies.self) private var deps
    @Environment(AppRouter.self) private var router
    @Environment(UserDataActions.self) private var userDataActions
    @State private var viewModel: JellyfinSearchViewModel?
    @State private var session: Session?
    // Bind the search field to local state so keystrokes typed before the VM
    // finishes its async construction aren't dropped on the floor (the old
    // `viewModel?.query = $0` was a silent no-op while viewModel was nil).
    @State private var query = ""
    @State private var scope: SearchScope = .all
    @Environment(\.appIdiom) private var idiom
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            // iOS/iPadOS scope row: OURS, in content — deliberately NOT `.searchScopes`.
            // The system scope capsule renders in the search presentation layer with its
            // own Liquid Glass drop shadow and no styling API — an unblended floating
            // slab on the flat floor (render-proven in SearchScopeBandPreview).
            //
            // Keyed on the VM's STATE, not `query.isEmpty`: the query flips on the
            // keystroke but the content swaps 350ms later (debounce), so a query-keyed
            // row moved in its own separate step — content pushed down first when typing,
            // row hiding first when clearing. State-keyed, the row enters exactly when
            // the placeholder gives way to the skeleton/results (and stays up through
            // the failure state, where switching scope re-runs the search) and leaves
            // exactly when the placeholder returns: one coordinated, symmetric motion.
            #if !os(tvOS)
            if scopesVisible {
                Picker("Search scope", selection: $scope) {
                    scopeOptions
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, AppLayout.contentHMargin(idiom: idiom))
                .padding(.top, Space.s8)
                .padding(.bottom, Space.s12)
                // Reduce Motion drops the slide for a plain fade (movement → cross-dissolve).
                .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
            }
            #endif

            Group {
                if let vm = viewModel, let session {
                    content(vm: vm, session: session)
                } else {
                    searchLoadingPlaceholder
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // iOS only: coordinates the scope row's slide with the content swap it rides on.
        // tvOS has no in-content row (scopes live in the system search chrome), so it
        // keeps its un-animated swaps instead of inheriting a purposeless transaction.
        #if !os(tvOS)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: scopesVisible)
        #endif
        // The SYSTEM search field on every platform — no custom in-content field. tvOS
        // renders the HIG search screen (system keyboard on top, results beneath) with
        // the native scope control. iPhone/iPad use the DRAWER placement: the wide bar
        // stacked below the nav bar (SwiftUI's analog of UIKit's `.stacked` — the Apple
        // TV app's search-tab layout), NOT the default iPadOS 26 trailing-corner field.
        // Being chrome-hosted keeps the field out of the keyboard-avoidance path that
        // shoved the old in-content bar off-screen.
        #if os(tvOS)
        .searchable(text: $query, prompt: Self.searchPrompt)
        .searchScopes($scope) {
            scopeOptions
        }
        #else
        .searchable(
            text: $query,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: Self.searchPrompt
        )
        // Keep the stacked drawer field IN PLACE while editing. Without this, activating
        // search lets the toolbar "adapt to the search presentation" — on iPadOS 26 the
        // wide drawer bar collapses into the top-trailing corner the moment it's tapped.
        .searchPresentationToolbarBehavior(.avoidHidingContent)
        #endif
        // Media titles are proper nouns and non-dictionary words ("Nosferatu", "Ex
        // Machina") — the old custom field disabled these deliberately; carry that
        // through to the system field (both propagate via the environment).
        .autocorrectionDisabled()
        .textInputAutocapitalization(.never)
        // Match the old custom-bar behavior: the first scroll motion drops the keyboard
        // (the system default keeps it up for plain ScrollViews). No-op on tvOS.
        .scrollDismissesKeyboard(.immediately)
        #if os(tvOS)
        // Drop the system search screen below the floating sidebar pill — see
        // `AppLayout.tvSearchTopClearance`. Applied INSIDE the stack (on the searchable
        // screen, not the NavigationStack) so pushed detail heroes stay full-bleed.
        .padding(.top, AppLayout.tvSearchTopClearance)
        #else
        // Keep a (title-less) nav bar so the .zoom push into item detail still has a
        // shared bar to hand its back button to — never `.toolbar(.hidden)` here.
        .navigationBarTitleDisplayMode(.inline)
        // Transparent bar, matching Home and the detail screens: the drawer + scope strip
        // otherwise paint the system bar material — an off-tone band that doesn't blend
        // with the daylight floor. Background only; the bar itself stays (zoom rule above).
        .toolbarBackground(.hidden, for: .navigationBar)
        // Soft top edge: the HIG-recommended style on iPadOS ("hard" is primarily macOS).
        // Over the flat floor it reads as no edge at all while still fading results that
        // scroll up under the drawer field.
        .scrollEdgeEffectStyle(.soft, for: .top)
        #endif
        .onChange(of: query) { _, newValue in
            viewModel?.query = newValue
        }
        .onChange(of: scope) { _, newValue in viewModel?.scope = newValue }
        // A scope outlives its search session otherwise: search "Batman" scoped to
        // Episodes, clear, search "Dune" — with the scope control hidden at idle, the
        // stale Episodes scope would silently narrow the new search. Ending a session
        // resets to All, so every fresh search starts unscoped, control visible or not.
        .onChange(of: scopesVisible) { _, visible in
            if !visible { scope = .all }
        }
        .screenFloor()
        .itemDetailNavigation()
        .task(id: router.activeServerID) {
            guard router.activeServerID != nil else { return }
            if session == nil {
                session = await deps.serverStore.active
            }
            if viewModel == nil, let session {
                let repo = await deps.jellyfinLibraryRepoFactory(session)
                let vm = JellyfinSearchViewModel(repo: repo, userDataActions: userDataActions)
                vm.start()
                // Seed any text/scope set during construction before wiring up — the
                // field is live while the VM builds, so both can change in that window.
                if !query.isEmpty { vm.query = query }
                if scope != .all { vm.scope = scope }
                viewModel = vm
            }
        }
        // Auto-recover a failed search when the network returns (or the app foregrounds online) by
        // re-running the current query. Gated on `isStalled` so a results page is never re-queried.
        .recoversFromOffline(isStalled: viewModel?.isStalled ?? false) { await viewModel?.retry() }
    }

    @ViewBuilder
    private func content(vm: JellyfinSearchViewModel, session: Session) -> some View {
        switch vm.state {
        case .idle:
            StatusStateView(
                title: "Find something to watch",
                systemImage: "magnifyingglass",
                message: "Movies, shows, and episodes from your library."
            )
        case .loading:
            searchLoadingPlaceholder
        case .loaded(let results):
            if results.movies.isEmpty && results.series.isEmpty && results.episodes.isEmpty {
                StatusStateView.searchNoResults
            } else {
                // The grid is an `.equatable()` child so a per-keystroke `query` change
                // can't re-render the tiles (see JellyfinSearchResultsView). The refine
                // overlay stays out here, in the reactive parent.
                JellyfinSearchResultsView(results: results, session: session, idiom: idiom)
                .equatable()
                // Floating indicator while refining — an overlay (not an inline row)
                // so the results don't shift down/up on every debounced keystroke.
                .overlay(alignment: .top) {
                    if vm.isSearching {
                        SearchRefiningSkeleton()
                    }
                }
            }
        case .failed(let message):
            StatusStateView.failure("Couldn't search your library", message: message)
        }
    }

    /// The scope row rides the VM's session flag so its show/hide is one motion with the
    /// content swap (see the comment at the row) — false while the VM is still building.
    private var scopesVisible: Bool {
        viewModel?.hasActiveSearch ?? false
    }

    /// Single source for the scope options — feeds BOTH the iOS in-content Picker and
    /// the tvOS `.searchScopes` builder, so the two platforms' scope lists can't drift.
    @ViewBuilder private var scopeOptions: some View {
        Text("All").tag(SearchScope.all)
        Text("Movies").tag(SearchScope.movies)
        Text("Shows").tag(SearchScope.series)
        Text("Episodes").tag(SearchScope.episodes)
    }

    private static let searchPrompt = "Search your library"

    private var searchLoadingPlaceholder: some View {
        ScrollView {
            PosterGridLoadingSkeleton(columns: posterCols, rows: 2)
        }
        .scrollDisabled(true)
    }

    private var posterCols: Int { AppLayout.searchPosterColumns(idiom: idiom) }
}

