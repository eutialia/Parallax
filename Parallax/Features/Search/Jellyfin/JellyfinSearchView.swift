import SwiftUI
import ParallaxJellyfin
import ParallaxCore

struct JellyfinSearchView: View {
    @Environment(AppDependencies.self) private var deps
    @Environment(AppRouter.self) private var router
    @State private var viewModel: JellyfinSearchViewModel?
    @State private var session: Session?
    // Bind the search field to local state so keystrokes typed before the VM
    // finishes its async construction aren't dropped on the floor (the old
    // `viewModel?.query = $0` was a silent no-op while viewModel was nil).
    @State private var query = ""
    @State private var scope: SearchScope = .all
    @FocusState private var searchFocused: Bool
    @Environment(\.appIdiom) private var idiom
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            // The search UI lives in the content (not the nav bar) so iPadOS 26 can't
            // hoist it into the sidebar chrome on focus. Scopes ride below the field and
            // only appear once there's a query — clearing the field drops them.
            VStack(spacing: Space.s12) {
                SearchBar(text: $query, prompt: "Search your library", focus: $searchFocused)
                if !query.isEmpty {
                    Picker("Search scope", selection: $scope) {
                        Text("All").tag(SearchScope.all)
                        Text("Movies").tag(SearchScope.movies)
                        Text("Shows").tag(SearchScope.series)
                        Text("Episodes").tag(SearchScope.episodes)
                    }
                    .pickerStyle(.segmented)
                    // Reduce Motion drops the slide for a plain fade (movement → cross-dissolve).
                    .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
                }
            }
            .padding(.horizontal, AppLayout.contentHMargin(idiom: idiom))
            .padding(.top, Space.s8)
            .padding(.bottom, Space.s12)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: query.isEmpty)

            Group {
                if let vm = viewModel, let session {
                    content(vm: vm, session: session)
                } else {
                    searchLoadingPlaceholder
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // Keep a (title-less) nav bar so the .zoom push into item detail still has a
        // shared bar to hand its back button to — never `.toolbar(.hidden)` here.
        #if !os(tvOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .onChange(of: query) { _, newValue in
            viewModel?.query = newValue
        }
        .onChange(of: scope) { _, newValue in viewModel?.scope = newValue }
        .screenFloor()
        .itemDetailNavigation()
        .task(id: router.activeServerID) {
            guard router.activeServerID != nil else { return }
            if session == nil {
                session = await deps.serverStore.active
            }
            if viewModel == nil, let session {
                let repo = await deps.jellyfinLibraryRepoFactory(session)
                let vm = JellyfinSearchViewModel(repo: repo)
                vm.start()
                // Seed any text/scope set during construction before wiring up — the
                // field is live while the VM builds, so both can change in that window.
                if !query.isEmpty { vm.query = query }
                if scope != .all { vm.scope = scope }
                viewModel = vm
            }
        }
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
                #if !os(tvOS)
                .tapToDismissKeyboard($searchFocused)
                #endif
        case .loading:
            searchLoadingPlaceholder
                #if !os(tvOS)
                .tapToDismissKeyboard($searchFocused)
                #endif
        case .loaded(let results):
            if results.movies.isEmpty && results.series.isEmpty && results.episodes.isEmpty {
                ContentUnavailableView.search
                    #if !os(tvOS)
                    .tapToDismissKeyboard($searchFocused)
                    #endif
            } else {
                // The grid is an `.equatable()` child so a per-keystroke `query` change
                // can't re-render the tiles (see JellyfinSearchResultsView). The dismiss
                // modifiers and the refine overlay stay out here, in the reactive parent.
                JellyfinSearchResultsView(
                    results: results,
                    session: session,
                    posterCols: posterCols,
                    landscapeCols: landscapeCols,
                    hMargin: AppLayout.contentHMargin(idiom: idiom)
                )
                .equatable()
                #if !os(tvOS)
                // Drive dismissal ourselves so scrolling drops the keyboard with the SAME
                // animation as the tap below (`.scrollDismissesKeyboard`'s built-in dismiss
                // uses a different curve). `.never` disables the system's version; then any
                // scroll (either direction) resigns focus the instant it starts.
                .scrollDismissesKeyboard(.never)
                .onScrollPhaseChange { _, newPhase in
                    if newPhase == .interacting { searchFocused = false }
                }
                .simultaneousGesture(TapGesture().onEnded { searchFocused = false })
                #endif
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
            #if !os(tvOS)
            .tapToDismissKeyboard($searchFocused)
            #endif
        }
    }

    private var searchLoadingPlaceholder: some View {
        ScrollView {
            PosterGridLoadingSkeleton(columns: posterCols, rows: 2)
        }
        .scrollDisabled(true)
    }

    private var posterCols: Int { AppLayout.searchPosterColumns(idiom: idiom) }
    private var landscapeCols: Int { AppLayout.searchLandscapeColumns(idiom: idiom) }
}

private extension View {
    /// Make a non-scrolling state fill its space and drop the keyboard when tapped.
    /// Scrollable results dismiss on scroll (via `onScrollPhaseChange`) plus their own
    /// tap gesture instead — a fill-frame tap target there would fight the poster tiles.
    func tapToDismissKeyboard(_ focus: FocusState<Bool>.Binding) -> some View {
        frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(.rect)
            .onTapGesture { focus.wrappedValue = false }
    }
}
