import SwiftUI
import ParallaxJellyfin
import ParallaxCore

struct LibraryListView: View {
    let session: Session

    @Environment(AppDependencies.self) private var deps
    @Environment(\.appIdiom) private var idiom
    @State private var viewModel: LibraryListViewModel?

    var body: some View {
        Group {
            if let vm = viewModel {
                switch vm.state {
                case .idle, .loading:
                    LibraryListLoadingPlaceholder()
                case .loaded:
                    ScrollView {
                        // Jellyfin renders library art at 16:9 with the name baked in, so
                        // these are wide banners: three-up on tvOS, two-up on iPad, one-up
                        // on iPhone.
                        let cols = AppLayout.libraryListColumns(idiom: idiom)
                        let gap = AppLayout.libraryListSpacing(idiom: idiom)
                        // Filter once per body pass, not inside `ForEach` (which would re-run it on
                        // every grid re-evaluation).
                        let supported = vm.collections.filter { isSupported($0.collectionType) }
                        LazyVGrid(
                            columns: Array(repeating: GridItem(.flexible(), spacing: gap), count: cols),
                            spacing: gap
                        ) {
                            ForEach(supported) { coll in
                                NavigationLink(value: coll) { LibraryCard(collection: coll, session: session) }
                                    .tvPosterButton()
                            }
                            // The virtual cross-library Favorites grid, riding the same banner
                            // grid as the server libraries (the iPad/tvOS sidebar lists it as a
                            // Libraries-section tab instead).
                            NavigationLink(value: FavoritesRoute()) { FavoritesCard() }
                                .tvPosterButton()
                        }
                        .padding(AppLayout.contentHMargin(idiom: idiom))
                    }
                    // Don't clip a focused card's lift at the scroll bounds.
                    .tvScrollClipDisabled()
                case .failed(let message):
                    ContentUnavailableView(
                        "Couldn't load libraries",
                        systemImage: "exclamationmark.triangle",
                        description: Text(message)
                    )
                }
            } else {
                LibraryListLoadingPlaceholder()
            }
        }
        .navigationDestination(for: MediaCollection.self) { coll in
            LibraryGridView(collection: coll, source: .jellyfin(session))
        }
        .navigationDestination(for: FavoritesRoute.self) { _ in
            LibraryGridView(scope: .favorites, title: "Favorites", session: session)
        }
        .task {
            if viewModel == nil {
                let repo = await deps.mediaRepoFactory(.jellyfin(session))
                viewModel = LibraryListViewModel(repo: repo)
                await viewModel?.load()
            }
        }
    }

    private func isSupported(_ type: CollectionType) -> Bool {
        switch type {
        case .movies, .tvShows: return true
        case .other: return false
        }
    }
}
