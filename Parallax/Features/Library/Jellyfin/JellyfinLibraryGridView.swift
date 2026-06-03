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
        .itemNavigationDestination()
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
            VStack(spacing: 0) {
                if !vm.availableGenres.isEmpty {
                    genreBar(vm: vm)
                }
                ScrollView {
                    MediaGrid(
                        items: vm.items,
                        columnMinWidth: 140,
                        onAppearLast: { Task { await vm.loadMore() } }
                    ) { item in
                        ItemNavigator(item: item, session: session) { tile(for: item) }
                    }
                    if vm.isLoadingMore {
                        ProgressView().padding()
                    }
                }
                .contentMargins(.horizontal, AppLayout.contentHMargin, for: .scrollContent)
            }
        }
    }

    @ViewBuilder
    private func genreBar(vm: JellyfinLibraryGridViewModel) -> some View {
        @Bindable var vm = vm
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Space.s8) {
                ForEach(vm.availableGenres, id: \.self) { genre in
                    let isSelected = vm.filter.genres == [genre]
                    Button {
                        vm.filter.genres = isSelected ? [] : [genre]
                    } label: {
                        Text(genre)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(isSelected ? Color.chipSelectedLabel : Color.secondaryLabel)
                            .padding(.horizontal, Space.s14).frame(height: 34)
                            .background(isSelected ? Color.chipSelectedFill : Color.fill, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, AppLayout.contentHMargin)
            .padding(.vertical, Space.s8)
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

    @ViewBuilder
    private func tile(for item: Item) -> some View {
        MediaTile(
            title: item.displayTitle,
            subtitle: subtitle(for: item),
            imageRef: image(for: item),
            imageKind: .primary,
            session: session,
            progress: nil,
            aspectRatio: JellyfinImage.poster,
            maxImageWidth: 600,
            badges: badges(for: item)
        )
    }

    private func badges(for item: Item) -> [String] {
        switch item {
        case .movie(let m): return m.posterBadges
        case .series(let s): return s.posterBadges
        case .episode: return []
        }
    }

    private func subtitle(for item: Item) -> String? {
        switch item {
        case .movie(let m): return m.year.map(String.init)
        case .series(let s): return s.year.map(String.init)
        case .episode(let e): return e.episodeCode
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
