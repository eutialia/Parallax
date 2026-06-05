import SwiftUI
import ParallaxJellyfin

struct JellyfinSearchView: View {
    @Environment(AppDependencies.self) private var deps
    @Environment(AppRouter.self) private var router
    @Environment(PlaybackPresenter.self) private var playback
    @State private var viewModel: JellyfinSearchViewModel?
    @State private var session: Session?
    // Bind the search field to local state so keystrokes typed before the VM
    // finishes its async construction aren't dropped on the floor (the old
    // `viewModel?.query = $0` was a silent no-op while viewModel was nil).
    @State private var query = ""
    @State private var scope: SearchScope = .all
    @Environment(\.horizontalSizeClass) private var hSize

    var body: some View {
        Group {
            if let vm = viewModel, let session {
                content(vm: vm, session: session)
            } else {
                searchLoadingPlaceholder
            }
        }
        .navigationTitle("Search")
        // Anchor the field to THIS screen's navigation bar. With the default
        // (automatic) placement, the `.search`-role tab hoisted the field into the
        // sidebarAdaptable chrome and hijacked the sidebar toggle (couldn't reopen
        // the sidebar without restarting). navigationBarDrawer keeps it self-contained.
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always))
        .searchScopes($scope) {
            Text("All").tag(SearchScope.all)
            Text("Movies").tag(SearchScope.movies)
            Text("Shows").tag(SearchScope.series)
            Text("Episodes").tag(SearchScope.episodes)
        }
        .onChange(of: query) { _, newValue in
            viewModel?.query = newValue
        }
        .onChange(of: scope) { _, newValue in viewModel?.scope = newValue }
        .itemZoomNavigation()
        .task(id: router.activeServerID) {
            guard router.activeServerID != nil else { return }
            if session == nil {
                session = await deps.serverStore.active
            }
            if viewModel == nil, let session {
                let repo = await deps.libraryRepoFactory(session)
                let vm = JellyfinSearchViewModel(repo: repo)
                vm.start()
                // Seed any text typed during construction before wiring up.
                if !query.isEmpty { vm.query = query }
                viewModel = vm
            }
        }
    }

    @ViewBuilder
    private func content(vm: JellyfinSearchViewModel, session: Session) -> some View {
        switch vm.state {
        case .idle:
            ContentUnavailableView("Search your library", systemImage: "magnifyingglass")
        case .loading:
            searchLoadingPlaceholder
        case .loaded(let results):
            if results.movies.isEmpty && results.series.isEmpty && results.episodes.isEmpty {
                ContentUnavailableView.search
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: Space.s26) {
                        if !results.series.isEmpty {
                            gridSection("Shows", count: results.series.count, cols: posterCols) {
                                ForEach(results.series) { s in
                                    ItemNavigator(item: .series(s), session: session) {
                                        MediaTile(title: s.title, subtitle: s.year.map(String.init), imageRef: s.imageRef(.primary), imageKind: .primary, session: session, progress: nil, aspectRatio: JellyfinImage.poster, maxImageWidth: 400)
                                    }
                                }
                            }
                        }
                        if !results.movies.isEmpty {
                            gridSection("Movies", count: results.movies.count, cols: posterCols) {
                                ForEach(results.movies) { m in
                                    ItemNavigator(item: .movie(m), session: session) {
                                        MediaTile(title: m.title, subtitle: m.year.map(String.init), imageRef: m.imageRef(.primary), imageKind: .primary, session: session, progress: nil, aspectRatio: JellyfinImage.poster, maxImageWidth: 400)
                                    }
                                }
                            }
                        }
                        if !results.episodes.isEmpty {
                            gridSection("Episodes", count: results.episodes.count, cols: landscapeCols) {
                                ForEach(results.episodes) { e in
                                    Button { playback.play(e.id, in: session) } label: {
                                        MediaTile(title: e.name, subtitle: e.seasonEpisodeLabel, imageRef: e.imageRef(.primary), imageKind: .primary, session: session, progress: nil, aspectRatio: JellyfinImage.landscape, maxImageWidth: 500)
                                    }.buttonStyle(.plain)
                                }
                            }
                        }
                    }
                    .padding(Space.s18)
                }
                // Floating indicator while refining — an overlay (not an inline row)
                // so the results don't shift down/up on every debounced keystroke.
                .overlay(alignment: .top) {
                    if vm.isSearching {
                        SearchRefiningSkeleton()
                    }
                }
            }
        case .failed(let message):
            ContentUnavailableView(
                "Search failed",
                systemImage: "exclamationmark.triangle",
                description: Text(message)
            )
        }
    }

    private var searchLoadingPlaceholder: some View {
        ScrollView {
            PosterGridLoadingSkeleton(columns: posterCols, rows: 2)
        }
        .scrollDisabled(true)
    }

    private var posterCols: Int { hSize == .regular ? 4 : 3 }
    private var landscapeCols: Int { hSize == .regular ? 3 : 2 }

    @ViewBuilder
    private func gridSection<Content: View>(_ title: String, count: Int, cols: Int, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Space.s12) {
            HStack(spacing: 6) {
                Text(title).font(.title3.weight(.bold))
                Text("\(count)").font(.subheadline).foregroundStyle(Color.secondaryLabel)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Space.s12), count: cols), spacing: Space.s18) {
                content()
            }
        }
    }
}
