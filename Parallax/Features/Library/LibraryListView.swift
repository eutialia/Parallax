import SwiftUI
import ParallaxJellyfin
import ParallaxCore

struct LibraryListView: View {
    let session: Session
    /// SMB libraries to surface alongside the Jellyfin collections — additive only: a failed
    /// SMB source contributes an empty array (silent), never touching the Jellyfin VM or its
    /// load/error states. Defaults empty so any non-iPhone caller is unaffected.
    var smbEntries: [LibraryEntry] = []

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
                            // SMB libraries after the Jellyfin banners, before Favorites — additive
                            // (driven by `smbEntries`, not the Jellyfin VM) so a failed SMB source
                            // simply contributes no cards. Drills into the source-aware, play-on-tap
                            // SMB grid via the `LibraryEntry` navigation value.
                            ForEach(smbEntries) { entry in
                                NavigationLink(value: entry) { LibraryCard(smb: entry.collection) }
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
        // SMB drill-down: an entry carries its own source, so the grid builds the right repo and
        // plays on tap. Distinct value type from the Jellyfin `MediaCollection` destination above,
        // so the two never collide.
        .navigationDestination(for: LibraryEntry.self) { entry in
            LibraryGridView(collection: entry.collection, source: entry.source)
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
