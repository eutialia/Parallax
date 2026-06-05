import SwiftUI
import ParallaxJellyfin

struct JellyfinLibraryListView: View {
    let session: Session

    @Environment(AppDependencies.self) private var deps
    @Environment(\.horizontalSizeClass) private var hSize
    @State private var viewModel: JellyfinLibraryListViewModel?

    var body: some View {
        Group {
            if let vm = viewModel {
                switch vm.state {
                case .idle, .loading:
                    LibraryListLoadingPlaceholder()
                case .loaded:
                    ScrollView {
                        // Jellyfin renders library art at 16:9 with the name baked in, so
                        // these are wide banners: two-up on iPad, one-up on iPhone.
                        let cols = hSize == .regular ? 2 : 1
                        LazyVGrid(
                            columns: Array(repeating: GridItem(.flexible(), spacing: Space.s12), count: cols),
                            spacing: Space.s12
                        ) {
                            ForEach(vm.collections.filter { isSupported($0.collectionType) }) { coll in
                                NavigationLink(value: coll) { LibraryCard(collection: coll, session: session) }
                                    .buttonStyle(.plain)
                            }
                        }
                        .padding(Space.s18)
                    }
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
            JellyfinLibraryGridView(collection: coll, session: session)
        }
        .task {
            if viewModel == nil {
                let repo = await deps.libraryRepoFactory(session)
                viewModel = JellyfinLibraryListViewModel(repo: repo)
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
