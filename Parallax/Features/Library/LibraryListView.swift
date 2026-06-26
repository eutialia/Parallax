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
    @Environment(AppRouter.self) private var router
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
                            // simply contributes no cards. Same cell + drill-down as the SMB-only
                            // list (`SMBLibraryCell` / `smbLibraryDestination()` below).
                            ForEach(smbEntries) { SMBLibraryCell(entry: $0) }
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
                    StatusStateView.failure("Couldn't load libraries", message: message)
                }
            } else {
                LibraryListLoadingPlaceholder()
            }
        }
        .navigationDestination(for: MediaCollection.self) { coll in
            LibraryGridView(collection: coll, source: .jellyfin(session))
        }
        // SMB drill-down — shared with the SMB-only list; distinct value type from the Jellyfin
        // `MediaCollection` destination above, so the two never collide.
        .smbLibraryDestination()
        .navigationDestination(for: FavoritesRoute.self) { _ in
            LibraryGridView(scope: .favorites, title: "Favorites", session: session)
        }
        // Keyed on the library revision so a "Visible Libraries" change (which bumps it) re-applies the
        // hidden set + reloads — the iPhone list then matches the iPad sidebar / tvOS column live.
        .task(id: router.libraryReloadToken) {
            let hidden = await deps.serverStore.hiddenCollectionIDs(for: session.id)
            if viewModel == nil {
                let repo = await deps.mediaRepoFactory(.jellyfin(session))
                viewModel = LibraryListViewModel(repo: repo, hiddenCollectionIDs: hidden)
            } else {
                viewModel?.hiddenCollectionIDs = hidden
            }
            await viewModel?.load()
        }
    }

    private func isSupported(_ type: CollectionType) -> Bool {
        switch type {
        case .movies, .tvShows: return true
        case .other: return false
        }
    }
}
