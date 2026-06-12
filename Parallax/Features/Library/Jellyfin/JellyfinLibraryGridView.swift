import SwiftUI
import ParallaxJellyfin

struct JellyfinLibraryGridView: View {
    let scope: LibraryScope
    let title: String
    let session: Session

    /// A server collection (the common case — sidebar tab or Library-list drill-down).
    init(collection: MediaCollection, session: Session) {
        self.scope = .collection(collection.id)
        self.title = collection.name
        self.session = session
    }

    /// The cross-library Favorites grid (movies + shows merged).
    init(scope: LibraryScope, title: String, session: Session) {
        self.scope = scope
        self.title = title
        self.session = session
    }

    @Environment(AppDependencies.self) private var deps
    @Environment(\.appIdiom) private var idiom
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Fixed poster columns — shared by the grid, its first-load placeholder, and the
    /// load-more strip so all three stay aligned. Denser on regular width (iPad).
    private var columns: Int { AppLayout.posterGridColumns(idiom: idiom) }
    @State private var viewModel: JellyfinLibraryGridViewModel?
    /// Skeleton capsule metrics for the header's loading state — tvOS-only, like the
    /// header itself. The real Genre/Sort chips are native `.glass` Menus that size
    /// themselves from their labels, so these approximate that footprint to keep the
    /// skeleton→real swap shift-free; the height reuses the app-wide control height.
    private let headerControlHeight: CGFloat = AppLayout.tvControlHeight
    private let genreChipWidth: CGFloat = 140
    private let sortChipWidth: CGFloat = 110

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
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        // iPhone + iPad carry ONE combined Sort menu in the nav bar's trailing edge — direction
        // tiles on top, sort fields below, genre folded in as a submenu. Unconditional (not
        // gated on the view model): a toolbar item inserted mid-push doesn't render until the
        // transition settles, so the button was blinking in late. tvOS instead keeps Genre +
        // Sort as in-content chips (see `gridContent`): toolbar items don't join its focus
        // engine, and the header must stay focus-reachable.
        .toolbar { libraryControlsToolbar }
        #endif
        .itemDetailNavigation()
        .screenFloor()
        .task {
            if viewModel == nil {
                let repo = await deps.libraryRepoFactory(session)
                viewModel = JellyfinLibraryGridViewModel(repo: repo, scope: scope)
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
                "Couldn't load \(title)",
                systemImage: "exclamationmark.triangle",
                description: Text(message)
            )
        } else if showsEmptyState(vm) {
            emptyState
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

    /// Loaded but nothing to show. Matters most for Favorites, which legitimately
    /// starts empty; a filtered-out collection gets the same treatment.
    private func showsEmptyState(_ vm: JellyfinLibraryGridViewModel) -> Bool {
        vm.items.isEmpty && vm.state == .loaded && !vm.isRefreshing
    }

    @ViewBuilder
    private var emptyState: some View {
        if case .favorites = scope {
            ContentUnavailableView(
                "No Favorites",
                systemImage: "heart",
                description: Text("Movies and shows you favorite will show up here.")
            )
        } else {
            ContentUnavailableView(
                "No Items",
                systemImage: "rectangle.stack",
                description: Text("Nothing in \(title) matches the current genre.")
            )
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
            Button("Try again") { Task { await vm.retryRefresh() } }
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
        // No `GlassEffectContainer` here: this row only renders on tvOS (iOS puts the
        // controls in the nav bar), and on tvOS the container re-renders native `.glass`
        // buttons in its own layer — glyphs drift off the discs and the glass desyncs
        // from the system focus lift (pixel-measured in the "Action row parity" preview).
        HStack(spacing: Space.s12) {
            Spacer(minLength: 0)
            if vm.isLoadingGenres {
                Capsule().fill(Color.fill).frame(width: genreChipWidth, height: headerControlHeight)
            } else if !vm.availableGenres.isEmpty {
                genreMenu(vm: vm)
            }
            sortMenu(vm: vm)
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
    /// Nav-bar placement of the library controls (iPhone + iPad): ONE menu carrying the
    /// Photos-style direction tiles, the sort fields, and Genre as a nested submenu —
    /// UIKit-bridged for the `.medium` element size (see `LibrarySortMenuButton`).
    /// Renders from plain values so it can mount before the view model exists.
    @ToolbarContentBuilder
    private var libraryControlsToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            LibrarySortMenuButton(
                sortField: viewModel?.sortField ?? ItemSort.defaultForLibrary.field,
                sortDirection: viewModel?.sortDirection ?? ItemSort.defaultForLibrary.direction,
                selectedGenre: viewModel?.selectedGenre,
                availableGenres: viewModel?.availableGenres ?? [],
                isEnabled: viewModel != nil,
                onSelectField: { viewModel?.sortField = $0 },
                onSelectDirection: { viewModel?.sortDirection = $0 },
                onSelectGenre: { viewModel?.selectedGenre = $0 }
            )
        }
    }
    #endif

    /// Inline-header Genre menu — only reachable on tvOS (`headerControls` is gated on
    /// `idiom == .tv`; iPhone/iPad fold the same `genrePicker` into the combined sort
    /// menu), so the native `.glass` style applies unconditionally.
    private func genreMenu(vm: JellyfinLibraryGridViewModel) -> some View {
        Menu {
            genrePicker(vm: vm)
        } label: {
            headerChip(vm.selectedGenre ?? "Genre", systemImage: "theatermasks")
        }
        // Native `.glass` (system focus platter + lift); selected = tinted glass.
        .buttonStyle(.glass)
        .tint(vm.selectedGenre != nil ? Color.chipSelectedFill : nil)
        .accessibilityLabel("Genre")
    }

    /// Single-select genre filter, collapsed from a scrolling chip bar into one menu: the inline
    /// `Picker` gives each genre the system's leading checkmark, with "All Genres" to clear.
    /// Shared by the tvOS chip and the combined sort menu's submenu (iPhone/iPad).
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

    /// Shared label for the header's menu buttons so Genre and Sort read identically.
    /// Bare — the enclosing Menu wears the native `.glass` style, which owns the capsule,
    /// metrics, and label color: the focused white platter inverts the label, and a forced
    /// `foregroundStyle` would survive that inversion and read gray-on-white. Selection
    /// shows via the menu's tint (set at the call site), not the label.
    private func headerChip(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .labelStyle(.titleAndIcon)
            .font(.subheadline.weight(.medium))
    }

    /// Inline-header Sort menu — tvOS-only like `genreMenu` (Genre stays its own chip
    /// there, so this menu is sort-only).
    private func sortMenu(vm: JellyfinLibraryGridViewModel) -> some View {
        Menu {
            sortPicker(vm: vm)
        } label: {
            headerChip("Sort", systemImage: "arrow.up.arrow.down")
        }
        .buttonStyle(.glass)
        .accessibilityLabel("Sort")
    }

    /// The tvOS sort menu body: same human-language direction labels as the iOS
    /// bridged menu (one vocabulary — `LibrarySortVocabulary`), but as an inline
    /// picker — the tile row is a touch-menu affordance the tvOS focus engine
    /// doesn't render. Genre stays its own header chip there.
    @ViewBuilder
    private func sortPicker(vm: JellyfinLibraryGridViewModel) -> some View {
        @Bindable var vm = vm
        Picker("Order", selection: $vm.sortDirection) {
            ForEach(LibrarySortVocabulary.directionOptions(for: vm.sortField), id: \.direction) { option in
                Label(option.title, systemImage: option.icon).tag(option.direction)
            }
        }
        .pickerStyle(.inline)
        Picker("Sort By", selection: $vm.sortField) {
            ForEach(ItemSort.Field.allCases, id: \.self) { f in
                Text(LibrarySortVocabulary.label(for: f)).tag(f)
            }
        }
        .pickerStyle(.inline)
    }

    @ViewBuilder
    private func tile(for item: Item) -> some View {
        MediaTile(
            title: item.displayTitle,
            imageRef: image(for: item),
            imageKind: .primary,
            session: session,
            progress: nil,
            watched: .init(item),
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

}
