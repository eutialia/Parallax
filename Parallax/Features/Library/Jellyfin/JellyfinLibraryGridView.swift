import SwiftUI
import ParallaxJellyfin

struct JellyfinLibraryGridView: View {
    let collectionID: CollectionID
    let session: Session

    @Environment(AppDependencies.self) private var deps
    @State private var viewModel: JellyfinLibraryGridViewModel?

    var body: some View {
        Group {
            if let vm = viewModel {
                gridContent(vm: vm)
            } else {
                ProgressView().padding(40)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if let vm = viewModel {
                    sortFilterMenu(vm: vm)
                }
            }
        }
        .navigationDestination(for: ItemNavigation.self) { nav in
            switch nav {
            case .movie(let id, let s): MovieDetailView(itemID: id, session: s)
            case .series(let id, let s): SeriesDetailView(itemID: id, session: s)
            case .season(let id, let s): SeasonDetailView(itemID: id, session: s)
            case .episode(let id, let s): EpisodeDetailView(itemID: id, session: s)
            }
        }
        .task {
            if viewModel == nil {
                let repo = await deps.libraryRepoFactory(session)
                viewModel = JellyfinLibraryGridViewModel(repo: repo, collectionID: collectionID)
                await viewModel?.load()
            }
        }
    }

    @ViewBuilder
    private func gridContent(vm: JellyfinLibraryGridViewModel) -> some View {
        if (vm.state == .idle || vm.state == .loading) && vm.items.isEmpty {
            ProgressView().padding(40)
        } else if case .failed(let message) = vm.state, vm.items.isEmpty {
            ContentUnavailableView(
                "Couldn't load library",
                systemImage: "exclamationmark.triangle",
                description: Text(message)
            )
        } else {
            ScrollView {
                MediaGrid(
                    items: vm.items,
                    columnMinWidth: 140,
                    onAppearLast: { Task { await vm.loadMore() } }
                ) { item in
                    NavigationLink(value: nav(for: item)) {
                        MediaTile(
                            title: title(for: item),
                            subtitle: subtitle(for: item),
                            imageRef: image(for: item),
                            imageKind: .primary,
                            session: session,
                            progress: nil,
                            aspectRatio: JellyfinImage.poster,
                            maxImageWidth: 600
                        )
                    }
                    .buttonStyle(.plain)
                }
                if vm.isLoadingMore {
                    ProgressView().padding()
                }
            }
            .contentMargins(.horizontal, AppLayout.contentHMargin, for: .scrollContent)
        }
    }

    @ViewBuilder
    private func sortFilterMenu(vm: JellyfinLibraryGridViewModel) -> some View {
        @Bindable var vm = vm
        Menu {
            Section("Sort") {
                ForEach(ItemSort.Field.allCases, id: \.self) { field in
                    Button {
                        let dir: ItemSort.Direction =
                            (vm.sort.field == field && vm.sort.direction == .ascending) ? .descending : .ascending
                        vm.sort = ItemSort(field: field, direction: dir)
                    } label: {
                        HStack {
                            Text(label(for: field))
                            if vm.sort.field == field {
                                Spacer()
                                Image(systemName: vm.sort.direction == .ascending ? "arrow.up" : "arrow.down")
                            }
                        }
                    }
                }
            }
            Section("Filter") {
                Picker("Watched", selection: $vm.filter.watchState) {
                    Text("All").tag(ItemFilter.WatchState.all)
                    Text("Played").tag(ItemFilter.WatchState.played)
                    Text("Unplayed").tag(ItemFilter.WatchState.unplayed)
                }
                Toggle("Favorites only", isOn: $vm.filter.favoritesOnly)
            }
        } label: {
            Image(systemName: "line.3.horizontal.decrease.circle")
        }
    }

    private func nav(for item: Item) -> ItemNavigation {
        switch item {
        case .movie(let m): return .movie(m.id, session)
        case .series(let s): return .series(s.id, session)
        case .episode(let e): return .episode(e.id, session)
        }
    }

    private func title(for item: Item) -> String {
        switch item {
        case .movie(let m): return m.title
        case .series(let s): return s.title
        case .episode(let e): return e.name
        }
    }

    private func subtitle(for item: Item) -> String? {
        switch item {
        case .movie(let m): return m.year.map(String.init)
        case .series(let s): return s.year.map(String.init)
        case .episode(let e):
            guard let s = e.parentIndexNumber, let ep = e.indexNumber else { return nil }
            return "S\(s)E\(ep)"
        }
    }

    private func image(for item: Item) -> ImageRef? {
        switch item {
        case .movie(let m): return m.imageRef(.primary)
        case .series(let s): return s.imageRef(.primary)
        case .episode(let e): return e.imageRef(.primary)
        }
    }

    private func label(for field: ItemSort.Field) -> String {
        switch field {
        case .title: return "Title"
        case .dateAdded: return "Date Added"
        case .releaseDate: return "Release Date"
        case .communityRating: return "Community Rating"
        case .officialRating: return "Official Rating"
        case .runtime: return "Runtime"
        case .playCount: return "Play Count"
        case .random: return "Random"
        }
    }
}
