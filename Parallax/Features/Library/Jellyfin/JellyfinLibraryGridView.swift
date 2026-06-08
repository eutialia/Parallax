import SwiftUI
import ParallaxJellyfin

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
    /// Header capsule height, Dynamic-Type-scaled for iPhone/iPad. Shared by the real controls and
    /// their loading placeholder so the swap stays height-neutral.
    @ScaledMetric(relativeTo: .subheadline) private var compactControlHeight: CGFloat = 46
    /// Header capsule height. Fixed-taller on tvOS (10-foot legibility — the SF Symbol needs
    /// vertical breathing room that 34pt didn't give at tvOS's larger `.subheadline`).
    private var headerControlHeight: CGFloat { idiom == .tv ? 56 : compactControlHeight }
    /// Skeleton capsule widths for the header's loading state — shared by the first-load
    /// placeholder and the genre-loading branch so both match the real chips' footprint.
    private let genreChipWidth: CGFloat = 140
    private let sortChipWidth: CGFloat = 150

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
        // Genre + Sort live INLINE in the content header (see `gridContent`), not the system
        // toolbar — on tvOS toolbar items don't join the focus engine (the drawn UINavigationBar
        // sits outside the content focus context), and keeping one layout across platforms is
        // simpler than a tvOS/iOS split. The nav bar just carries the library title.
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
            ScrollView {
                gridScrollContent(vm: vm)
            }
            .contentMargins(.horizontal, AppLayout.contentHMargin(idiom: idiom), for: .scrollContent)
            // Overscan room so a focused poster's lift/shadow at the grid's top or bottom edge
            // has space to grow WITHIN the clip — the title-safe-margin approach, instead of
            // disabling the scroll clip (which let scrolled rows bleed up over the genre/nav
            // chrome). tvOS only; iOS has no focus lift. See `safeAreaInset` below.
            .contentMargins(.vertical, idiom == .tv ? Space.s40 : 0, for: .scrollContent)
            // Genre + Sort as real top chrome: pinned above the grid, clipped scroll content slides
            // UNDER it (and stops at its edge), so posters never paint over the controls. Both are
            // focusable in-content menus sitting side by side (Genre ⇄ Sort is left/right, row ⇄
            // grid is up/down — all cardinal moves the tvOS focus engine handles cleanly). The
            // refresh-error banner rides along as part of the header.
            .safeAreaInset(edge: .top, spacing: 0) {
                VStack(spacing: 0) {
                    headerControls(vm: vm)
                    if let message = vm.refreshErrorMessage {
                        refreshErrorBanner(message: message, vm: vm)
                    }
                }
                // Opaque screen-floor backing so rows scrolling UNDER the header are hidden by it
                // (the scroll view's bounds extend up behind the inset; the clip alone doesn't hide
                // them). Matches `appScreenBackground` so the band reads as the screen, not a bar.
                .background(Color.background)
            }
        }
    }

    /// Full-screen placeholder only on the very first load — while genres are still
    /// in flight. Sort/filter/genre changes reload the grid but keep the header controls.
    private func isInitialLoad(_ vm: JellyfinLibraryGridViewModel) -> Bool {
        vm.items.isEmpty && (vm.state == .idle || (vm.state == .loading && vm.isLoadingGenres))
    }

    private var gridAnimation: Animation? {
        if reduceMotion { return nil }
        #if os(tvOS)
        // Instant swap on tvOS: a crossfade replacing the grid's focusable content makes the focus
        // engine re-evaluate for the animation's whole duration, parking focus off the header's
        // Genre/Sort button until it settles. No animation window → focus stays put. iOS has no
        // focus to lose, so it keeps the crossfade.
        return nil
        #else
        return .smooth
        #endif
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
            // Stale-while-revalidate: dim the outgoing page (`gridDimmed` tracks `isRefreshing`)
            // during the API round-trip, then crossfade back when it clears. Keyed on `isRefreshing`
            // — the only input the opacity derives from — so iOS crossfades in BOTH directions. tvOS
            // gets the instant swap for free: `gridAnimation` is nil there, so no animation window
            // opens to hold the focus/input system and block re-opening the menu at the pick moment.
            .opacity(gridDimmed(vm))
            .allowsHitTesting(!vm.isRefreshing)
            .animation(gridAnimation, value: vm.isRefreshing)
            if vm.isLoadingMore {
                AdaptivePosterGridLoadingSkeleton(tileCount: columns, fixedColumns: columns)
                    .padding(.vertical, Space.s12)
            }
        }
    }

    /// Full-screen first-load placeholder: genre-pill row above a poster-grid skeleton,
    /// laid out to match the loaded grid so content doesn't shift in when it arrives.
    private var libraryGridLoadingPlaceholder: some View {
        ScrollView {
            AdaptivePosterGridLoadingSkeleton(tileCount: columns * 3, fixedColumns: columns)
        }
        .scrollDisabled(true)
        .contentMargins(.horizontal, AppLayout.contentHMargin(idiom: idiom), for: .scrollContent)
        // Match the loaded grid's vertical overscan (line up `gridContent`) so the first poster row
        // lands at the same y when the skeleton swaps out — no 40pt jump on tvOS load.
        .contentMargins(.vertical, idiom == .tv ? Space.s40 : 0, for: .scrollContent)
        // Match the loaded grid's header geometry (two centered capsules, opaque so content scrolls
        // under) so the swap to the real Genre/Sort controls is shift-free.
        .safeAreaInset(edge: .top, spacing: 0) {
            HStack(spacing: Space.s12) {
                Spacer(minLength: 0)
                Capsule().fill(Color.fill).frame(width: genreChipWidth, height: headerControlHeight)
                Capsule().fill(Color.fill).frame(width: sortChipWidth, height: headerControlHeight)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, AppLayout.contentHMargin(idiom: idiom))
            .padding(.vertical, Space.s8)
            .background(Color.background)
        }
    }

    /// Centered Genre + Sort control row. Holds a stable height across loading → loaded so the
    /// grid below never shifts. Genre collapses out when the library has no genres.
    @ViewBuilder
    private func headerControls(vm: JellyfinLibraryGridViewModel) -> some View {
        HStack(spacing: Space.s12) {
            Spacer(minLength: 0)
            if vm.isLoadingGenres {
                Capsule().fill(Color.fill).frame(width: genreChipWidth, height: headerControlHeight)
            } else if !vm.availableGenres.isEmpty {
                genreMenu(vm: vm)
            }
            sortFilterMenu(vm: vm)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, AppLayout.contentHMargin(idiom: idiom))
        .padding(.vertical, Space.s8)
        .animation(reduceMotion ? nil : .smooth, value: vm.isLoadingGenres)
    }

    /// Single-select genre filter, collapsed from a scrolling chip bar into one menu: the inline
    /// `Picker` gives each genre the system's leading checkmark, with "All Genres" to clear.
    @ViewBuilder
    private func genreMenu(vm: JellyfinLibraryGridViewModel) -> some View {
        @Bindable var vm = vm
        // Lens between the repo's `[String]` genre filter and the menu's single optional selection
        // (nil = no filter). One genre at a time — a title can carry several, so this is "show me
        // everything tagged X", not a mutually-exclusive bucket.
        let selection = Binding<String?>(
            get: { vm.filter.genres.first },
            set: { vm.filter.genres = $0.map { [$0] } ?? [] }
        )
        Menu {
            Picker("Genre", selection: selection) {
                Text("All Genres").tag(String?.none)
                ForEach(vm.availableGenres, id: \.self) { genre in
                    Text(genre).tag(String?.some(genre))
                }
            }
            .pickerStyle(.inline)
        } label: {
            headerChip(
                vm.filter.genres.first ?? "Genre",
                systemImage: "theatermasks",
                isSelected: !vm.filter.genres.isEmpty
            )
        }
        .tvChipButton()
        .accessibilityLabel("Genre")
    }

    /// Shared Liquid Glass capsule for the header's menu buttons so Genre and Sort read
    /// identically — the same `.glassEffect(.regular…)` + hairline language as `GlassSurface`'s
    /// `glassPanel`/`glassBar`. The hairline is the theme-adaptive `glassBorder` (NOT the
    /// dark-pinned `heroGlassBorder` the photo-context controls use): this header floats over the
    /// solid screen, so the border must track light/dark like the rest of the chrome. Selected
    /// genre tints the glass to stand out; the focus lift comes from `.tvChipButton()` on the Menu
    /// (tvOS has no touch/pointer, so glass `.interactive()` wouldn't fire — the focus effect is
    /// what responds to the remote).
    private func headerChip(_ title: String, systemImage: String, isSelected: Bool = false) -> some View {
        HStack(spacing: Space.s8) {
            Image(systemName: systemImage)
            Text(title)
        }
        .font(.subheadline.weight(.medium))
        .foregroundStyle(isSelected ? Color.chipSelectedLabel : Color.secondaryLabel)
        .padding(.horizontal, Space.s14)
        .frame(height: headerControlHeight)
        .glassEffect(isSelected ? .regular.tint(Color.chipSelectedFill) : .regular, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.glassBorder, lineWidth: 1))
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
            headerChip("Sort & Filter", systemImage: "line.3.horizontal.decrease")
        }
        .tvChipButton()
        .accessibilityLabel("Sort and Filter")
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
