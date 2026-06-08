import SwiftUI
import ParallaxJellyfin

private struct LibraryGridAnimationTrigger: Equatable {
    var isRefreshing: Bool
    var refreshGeneration: UInt
}

struct JellyfinLibraryGridView: View {
    let collection: MediaCollection
    let session: Session

    @Environment(AppDependencies.self) private var deps
    @Environment(\.appIdiom) private var idiom
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Fixed poster columns — shared by the grid, its first-load placeholder, and the
    /// load-more strip so all three stay aligned. Denser on regular width (iPad).
    private var columns: Int { AppLayout.posterGridColumns(idiom: idiom) }
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
        .appScreenBackground()
        // The grid owns its own title (the library name) so BOTH entry points — the
        // sidebar's direct library tab and the Library-list drill-down — show it
        // identically, without each call site re-specifying it. Inline so the name
        // shares the bar row with the sort/filter button instead of dropping to its
        // own large-title row.
        .navigationTitle(collection.name)
        #if !os(tvOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
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
        if isInitialLoad(vm) {
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
                    .animation(reduceMotion ? nil : .smooth, value: vm.isLoadingGenres)
                if let message = vm.refreshErrorMessage {
                    refreshErrorBanner(message: message, vm: vm)
                }
                ScrollView {
                    gridScrollContent(vm: vm)
                }
                .contentMargins(.horizontal, AppLayout.contentHMargin(idiom: idiom), for: .scrollContent)
            }
        }
    }

    /// Full-screen placeholder only on the very first load — while genres are still
    /// in flight. Sort/filter/genre changes reload the grid but keep the genre bar.
    private func isInitialLoad(_ vm: JellyfinLibraryGridViewModel) -> Bool {
        vm.items.isEmpty && (vm.state == .idle || (vm.state == .loading && vm.isLoadingGenres))
    }

    private var gridAnimation: Animation? { reduceMotion ? nil : .smooth }

    private func gridAnimationTrigger(_ vm: JellyfinLibraryGridViewModel) -> LibraryGridAnimationTrigger {
        LibraryGridAnimationTrigger(isRefreshing: vm.isRefreshing, refreshGeneration: vm.refreshGeneration)
    }

    private func gridDimmed(_ vm: JellyfinLibraryGridViewModel) -> Double {
        vm.isRefreshing && !reduceMotion ? 0.45 : 1
    }

    private func refreshErrorBanner(message: String, vm: JellyfinLibraryGridViewModel) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.s8) {
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.subheadline)
                .foregroundStyle(Color.secondaryLabel)
                .lineLimit(2)
            Spacer(minLength: Space.s8)
            Button("Try Again") { Task { await vm.retryRefresh() } }
                .font(.subheadline.weight(.semibold))
        }
        .padding(.horizontal, AppLayout.contentHMargin(idiom: idiom))
        .padding(.vertical, Space.s8)
        .background(Color.fill)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func gridScrollContent(vm: JellyfinLibraryGridViewModel) -> some View {
        if vm.items.isEmpty, vm.state == .loading {
            AdaptivePosterGridLoadingSkeleton(tileCount: columns * 3, fixedColumns: columns)
        } else {
            MediaGrid(
                items: vm.items,
                fixedColumns: columns,
                onAppearLast: { Task { await vm.loadMore() } }
            ) { item in
                ItemNavigator(item: item, session: session) { tile(for: item) }
            }
            // Stale-while-revalidate: dim the outgoing page during the API round-trip,
            // then crossfade back to full opacity when refreshGeneration bumps.
            .opacity(gridDimmed(vm))
            .allowsHitTesting(!vm.isRefreshing)
            .animation(gridAnimation, value: gridAnimationTrigger(vm))
            if vm.isLoadingMore {
                AdaptivePosterGridLoadingSkeleton(tileCount: columns, fixedColumns: columns)
                    .padding(.vertical, Space.s12)
            }
        }
    }

    /// Full-screen first-load placeholder: genre-pill row above a poster-grid skeleton,
    /// laid out to match the loaded grid so content doesn't shift in when it arrives.
    private var libraryGridLoadingPlaceholder: some View {
        VStack(spacing: 0) {
            genrePlaceholder
            ScrollView {
                AdaptivePosterGridLoadingSkeleton(tileCount: columns * 3, fixedColumns: columns)
            }
            .scrollDisabled(true)
            .contentMargins(.horizontal, AppLayout.contentHMargin(idiom: idiom), for: .scrollContent)
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
            .padding(.horizontal, AppLayout.contentHMargin(idiom: idiom))
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
                    .tvChipButton()
                }
            }
            .padding(.horizontal, AppLayout.contentHMargin(idiom: idiom))
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
        .tvChipButton()
    }

    @ViewBuilder
    private func tile(for item: Item) -> some View {
        MediaTile(
            title: item.displayTitle,
            imageRef: image(for: item),
            imageKind: .primary,
            session: session,
            progress: nil,
            aspectRatio: JellyfinImage.poster,
            maxImageWidth: 600
        )
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
