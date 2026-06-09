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
        // The grid owns its own title (the library name) so both iOS entry points — iPhone's
        // Library-list drill-down and iPad's direct sidebar tab — show it identically. Inline so
        // the name shares the bar row with the sort/filter button instead of a large-title row.
        // tvOS deliberately omits it: the collapsed sidebar's top-left already carries the library
        // name (from the selected tab's label), so an in-content title would just duplicate it.
        #if !os(tvOS)
        .navigationTitle(collection.name)
        .navigationBarTitleDisplayMode(.inline)
        // iPhone + iPad carry Genre/Sort in the nav bar's trailing edge — iPhone as ONE combined
        // menu button (its bar is too narrow for two chips beside the title), iPad as two menus on
        // the same row as the back button. tvOS instead keeps them in-content (see `gridContent`):
        // toolbar items don't join its focus engine, and the header must stay focus-reachable.
        .toolbar {
            if let vm = viewModel {
                libraryControlsToolbar(vm: vm)
            }
        }
        #endif
        .itemDetailNavigation()
        .screenFloor()
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
                VStack(spacing: 0) {
                    // tvOS: Genre + Sort scroll WITH the grid (in-content), side by side (Genre ⇄
                    // Sort is left/right, header ⇄ grid is up/down). They live inside the focusable
                    // scroll so the focus engine can climb back up to them after scrolling down — a
                    // pinned header sits outside that scroll and can't be refocused via the remote.
                    // iPhone/iPad carry the controls in the nav bar instead (see `body`'s toolbar).
                    if idiom == .tv {
                        headerControls(vm: vm)
                        if let message = vm.refreshErrorMessage {
                            refreshErrorBanner(message: message, vm: vm)
                        }
                    }
                    gridScrollContent(vm: vm)
                }
            }
            .contentMargins(.horizontal, AppLayout.contentHMargin(idiom: idiom), for: .scrollContent)
            // Overscan room so a focused poster's (or the tvOS header chip's) lift/shadow at the
            // grid's top or bottom edge has space to grow WITHIN the clip — the title-safe-margin
            // approach, instead of disabling the scroll clip (which let scrolled rows bleed over the
            // chrome). tvOS only; iOS has no focus lift.
            .contentMargins(.vertical, idiom == .tv ? Space.s40 : 0, for: .scrollContent)
            // iPhone/iPad: pin the refresh-error banner as a top inset — it's a transient alert and
            // there's no focus engine to trap. tvOS folds the banner into the scroll content above.
            .safeAreaInset(edge: .top, spacing: 0) {
                if idiom != .tv, let message = vm.refreshErrorMessage {
                    refreshErrorBanner(message: message, vm: vm)
                        .background(Color.background)
                }
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
            VStack(spacing: 0) {
                // Match the loaded grid's tvOS in-content header geometry (two centered capsules) so
                // the swap to the real Genre/Sort controls is shift-free. iPhone/iPad carry those in
                // the nav bar, not the content, so they skip the placeholder capsules. Horizontal
                // inset comes from `contentMargins`, like the header itself.
                if idiom == .tv {
                    HStack(spacing: Space.s12) {
                        Spacer(minLength: 0)
                        Capsule().fill(Color.fill).frame(width: genreChipWidth, height: headerControlHeight)
                        Capsule().fill(Color.fill).frame(width: sortChipWidth, height: headerControlHeight)
                        Spacer(minLength: 0)
                    }
                    // Matches `headerControls`' padding so the skeleton→real-controls swap doesn't
                    // shift the grid down (8pt top + 30pt bottom gap to the first poster row).
                    .padding(.top, Space.s8)
                    .padding(.bottom, Space.s30)
                }
                AdaptivePosterGridLoadingSkeleton(tileCount: columns * 3, fixedColumns: columns)
            }
        }
        .scrollDisabled(true)
        .contentMargins(.horizontal, AppLayout.contentHMargin(idiom: idiom), for: .scrollContent)
        // Match the loaded grid's vertical overscan (line up `gridContent`) so the first poster row
        // lands at the same y when the skeleton swaps out — no 40pt jump on tvOS load.
        .contentMargins(.vertical, idiom == .tv ? Space.s40 : 0, for: .scrollContent)
    }

    /// Centered Genre + Sort control row — tvOS only, living INSIDE the scroll content (see
    /// `gridContent`) so the focus engine can scroll back up to it. Holds a stable height across
    /// loading → loaded so the grid below never shifts; Genre collapses out when the library has no
    /// genres. Horizontal inset comes from the scroll view's `contentMargins`, not local padding.
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
        .padding(.top, Space.s8)
        // Clear the first poster row at 10-foot distance: 8pt crowded the chips against the grid
        // and let their focus lift collide with row 1's. iOS carries these controls in the nav bar,
        // never in-content, so this gap is tvOS-only by construction. Keep in sync with the
        // loading placeholder's header padding so the skeleton→real swap stays shift-free.
        .padding(.bottom, Space.s30)
        // The two chips are centered, so they only sit above the middle columns. The tvOS focus
        // engine searches straight UP from the focused poster, so from the outer columns there's no
        // chip in line and pressing Up does nothing. `focusSection()` turns the row's full width
        // into one focus target that diverts to the nearest chip — Up from ANY column now reaches
        // Genre/Sort. (Apple's tvOS catalog sample applies it for this exact above-the-fold case.)
        .tvFocusSection()
        .animation(reduceMotion ? nil : .smooth, value: vm.isLoadingGenres)
    }

    #if !os(tvOS)
    /// Any active library filter — genre, watch state, or favorites (sort order isn't a filter).
    /// Drives the iPhone combined button's filled-funnel state so an applied filter is visible
    /// without opening the menu.
    private func isFiltered(_ vm: JellyfinLibraryGridViewModel) -> Bool {
        vm.selectedGenre != nil || vm.filter.watchState != .all || vm.filter.favoritesOnly
    }

    /// Nav-bar placement of the library controls (iPhone + iPad), on the trailing edge of the bar
    /// that carries the back button. iPad spreads Genre + Sort across two menus (room to spare);
    /// iPhone collapses them into ONE menu button whose Genre is a nested submenu, since its
    /// narrower bar can't carry two chips beside the title. Both reuse `genrePicker` /
    /// `sortFilterPicker`, with plain `Label`s so the system glass treats them as standard bar
    /// buttons (the inline chips' own `.glassEffect` would double up). tvOS is excluded at compile
    /// time (`.topBarTrailing` is iOS-only) and keeps the focusable in-content header.
    @ToolbarContentBuilder
    private func libraryControlsToolbar(vm: JellyfinLibraryGridViewModel) -> some ToolbarContent {
        if idiom == .regular {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if !vm.availableGenres.isEmpty {
                    Menu {
                        genrePicker(vm: vm)
                    } label: {
                        Label(vm.selectedGenre ?? "Genre", systemImage: "theatermasks")
                            .labelStyle(.titleAndIcon)
                    }
                    .accessibilityLabel("Genre")
                }
                Menu {
                    sortFilterPicker(vm: vm)
                } label: {
                    Label("Sort & Filter", systemImage: "line.3.horizontal.decrease")
                        .labelStyle(.titleAndIcon)
                }
                .accessibilityLabel("Sort and Filter")
            }
        } else {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    // Genre as a nested submenu (it can be a long list); Sort / Order / Filter ride
                    // inline beneath it as the menu's lower sections.
                    if !vm.availableGenres.isEmpty {
                        Menu {
                            genrePicker(vm: vm)
                        } label: {
                            Label(vm.selectedGenre ?? "Genre", systemImage: "theatermasks")
                        }
                    }
                    sortFilterPicker(vm: vm)
                } label: {
                    // The single button hides the genre/watch/favorites state inside the menu, so
                    // the funnel fills when any filter is active — the affordance the iPad genre
                    // label and the tvOS chip's isSelected tint provide on their own.
                    Label(
                        "Sort & Filter",
                        systemImage: isFiltered(vm)
                            ? "line.3.horizontal.decrease.circle.fill"
                            : "line.3.horizontal.decrease.circle"
                    )
                }
                .accessibilityLabel(vm.availableGenres.isEmpty ? "Sort and Filter" : "Sort, filter, and genre")
            }
        }
    }
    #endif

    /// Inline-header Genre menu (iPhone + tvOS) — the glass chip label. iPad uses the same
    /// `genrePicker` content under a plain nav-bar label (see `libraryControlsToolbar`).
    private func genreMenu(vm: JellyfinLibraryGridViewModel) -> some View {
        Menu {
            genrePicker(vm: vm)
        } label: {
            headerChip(
                vm.selectedGenre ?? "Genre",
                systemImage: "theatermasks",
                isSelected: vm.selectedGenre != nil
            )
        }
        .tvChipButton()
        .accessibilityLabel("Genre")
    }

    /// Single-select genre filter, collapsed from a scrolling chip bar into one menu: the inline
    /// `Picker` gives each genre the system's leading checkmark, with "All Genres" to clear. Shared
    /// by the inline chip (iPhone/tvOS) and the nav-bar menu (iPad).
    @ViewBuilder
    private func genrePicker(vm: JellyfinLibraryGridViewModel) -> some View {
        @Bindable var vm = vm
        Picker("Genre", selection: $vm.selectedGenre) {
            Text("All Genres").tag(String?.none)
            ForEach(vm.availableGenres, id: \.self) { genre in
                Text(genre).tag(String?.some(genre))
            }
        }
        .pickerStyle(.inline)
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

    /// Inline-header Sort & Filter menu (iPhone + tvOS) — the glass chip label. iPad uses the same
    /// `sortFilterPicker` content under a plain nav-bar label (see `libraryControlsToolbar`).
    private func sortFilterMenu(vm: JellyfinLibraryGridViewModel) -> some View {
        Menu {
            sortFilterPicker(vm: vm)
        } label: {
            headerChip("Sort & Filter", systemImage: "line.3.horizontal.decrease")
        }
        .tvChipButton()
        .accessibilityLabel("Sort and Filter")
    }

    /// Sort field + order, then a Filter section. Field + direction are separate inline Pickers
    /// (not a hand-rolled row with a trailing arrow), so every selected item gets the system's
    /// LEADING checkmark column — aligned with the Filter watch-state picker, and no 0-height slot.
    /// Shared by the inline chip (iPhone/tvOS) and the nav-bar menu (iPad).
    @ViewBuilder
    private func sortFilterPicker(vm: JellyfinLibraryGridViewModel) -> some View {
        @Bindable var vm = vm
        Picker("Sort By", selection: $vm.sortField) {
            ForEach(ItemSort.Field.allCases, id: \.self) { f in
                Text(label(for: f)).tag(f)
            }
        }
        .pickerStyle(.inline)
        Picker("Order", selection: $vm.sortDirection) {
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
