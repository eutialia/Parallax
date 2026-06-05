import SwiftUI
import ParallaxJellyfin

struct JellyfinLibraryGridView: View {
    let collection: MediaCollection
    let session: Session

    @Environment(AppDependencies.self) private var deps
    @State private var viewModel: JellyfinLibraryGridViewModel?
    /// Genre-chip height scales with Dynamic Type (relative to the chip's `.subheadline`
    /// label). Shared by the real chip and its loading placeholder so the swap stays
    /// height-neutral.
    @ScaledMetric(relativeTo: .subheadline) private var genreChipHeight: CGFloat = 34

    var body: some View {
        Group {
            if let vm = viewModel {
                gridContent(vm: vm)
            } else {
                libraryGridLoadingPlaceholder
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.background)
        // The grid owns its own title (the library name) so BOTH entry points — the
        // sidebar's direct library tab and the Library-list drill-down — show it
        // identically, without each call site re-specifying it. Inline so the name
        // shares the bar row with the sort/filter button instead of dropping to its
        // own large-title row.
        .navigationTitle(collection.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if let vm = viewModel {
                    sortFilterMenu(vm: vm)
                }
            }
        }
        .itemZoomNavigation()
        .task {
            if viewModel == nil {
                let repo = await deps.libraryRepoFactory(session)
                viewModel = JellyfinLibraryGridViewModel(repo: repo, collectionID: collection.id)
                await viewModel?.load()
            }
        }
    }

    @ViewBuilder
    private func gridContent(vm: JellyfinLibraryGridViewModel) -> some View {
        if (vm.state == .idle || vm.state == .loading) && vm.items.isEmpty {
            libraryGridLoadingPlaceholder
        } else if case .failed(let message) = vm.state, vm.items.isEmpty {
            ContentUnavailableView(
                "Couldn't load library",
                systemImage: "exclamationmark.triangle",
                description: Text(message)
            )
        } else {
            VStack(spacing: 0) {
                // Reserve the genre row from the first paint so the grid doesn't
                // "drop" when genres (loaded concurrently) land a beat later. The
                // animation smooths the one place this can still move: a library that
                // turns out to have NO genres collapses the placeholder gently.
                genreSection(vm: vm)
                    .animation(.smooth, value: vm.isLoadingGenres)
                ScrollView {
                    MediaGrid(
                        items: vm.items,
                        columnMinWidth: 140,
                        onAppearLast: { Task { await vm.loadMore() } }
                    ) { item in
                        ItemNavigator(item: item, session: session) { tile(for: item) }
                    }
                    if vm.isLoadingMore {
                        AdaptivePosterGridLoadingSkeleton(tileCount: 3)
                            .padding(.vertical, Space.s12)
                    }
                }
                .contentMargins(.horizontal, AppLayout.contentHMargin, for: .scrollContent)
            }
        }
    }

    /// Full-screen first-load placeholder: genre-pill row above a poster-grid skeleton,
    /// laid out to match the loaded grid so content doesn't shift in when it arrives.
    private var libraryGridLoadingPlaceholder: some View {
        VStack(spacing: 0) {
            genrePlaceholder
            ScrollView {
                AdaptivePosterGridLoadingSkeleton(tileCount: 12)
            }
            .scrollDisabled(true)
            .contentMargins(.horizontal, AppLayout.contentHMargin, for: .scrollContent)
        }
    }

    /// Genre row that holds a stable height across loading → loaded so the grid
    /// below never shifts. While genres load it shows placeholder pills; once loaded
    /// it shows the real chips, or collapses if the library has no genres.
    @ViewBuilder
    private func genreSection(vm: JellyfinLibraryGridViewModel) -> some View {
        if vm.isLoadingGenres {
            genrePlaceholder
        } else if !vm.availableGenres.isEmpty {
            genreBar(vm: vm)
        }
    }

    private var genrePlaceholder: some View {
        // Same geometry as genreBar (34pt pills + Space.s8 vertical padding) so the
        // swap to real chips is height-neutral.
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Space.s8) {
                ForEach([64, 52, 78, 60, 70, 56], id: \.self) { width in
                    Capsule().fill(Color.fill)
                        .frame(width: CGFloat(width), height: genreChipHeight)
                }
            }
            .padding(.horizontal, AppLayout.contentHMargin)
            .padding(.vertical, Space.s8)
        }
        .scrollDisabled(true)
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
                            .padding(.horizontal, Space.s14).frame(height: genreChipHeight)
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
        // Field + direction are separate inline Pickers (not a hand-rolled row with a
        // trailing arrow), so every selected item gets the system's LEADING checkmark
        // column — aligned with the Filter watch-state picker, and no 0-height slot.
        let field = Binding(
            get: { vm.sort.field },
            set: { vm.sort = ItemSort(field: $0, direction: vm.sort.direction) }
        )
        let direction = Binding(
            get: { vm.sort.direction },
            set: { vm.sort = ItemSort(field: vm.sort.field, direction: $0) }
        )
        Menu {
            Picker("Sort By", selection: field) {
                ForEach(ItemSort.Field.allCases, id: \.self) { f in
                    Text(label(for: f)).tag(f)
                }
            }
            .pickerStyle(.inline)
            Picker("Order", selection: direction) {
                Label("Ascending", systemImage: "arrow.up").tag(ItemSort.Direction.ascending)
                Label("Descending", systemImage: "arrow.down").tag(ItemSort.Direction.descending)
            }
            .pickerStyle(.inline)
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
        case .episode(let e): return e.seasonEpisodeLabel
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
