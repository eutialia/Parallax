import SwiftUI
import ParallaxJellyfin
import ParallaxCore

/// Skeleton capsule metrics for the tvOS in-content header's loading state — shared by
/// the live `headerControls` (the `isLoadingGenres` capsule) and the first-load
/// `LibraryGridLoadingPlaceholder` so the skeleton→real-controls swap is shift-free. The
/// real Genre/Sort chips are native `.glass` Menus that size themselves from their labels,
/// so these approximate that footprint; the height reuses the app-wide control height.
private enum LibraryHeaderChip {
    static let height: CGFloat = AppLayout.tvControlHeight
    static let genreWidth: CGFloat = 140
    static let sortWidth: CGFloat = 110
}

/// `LibraryGridView.body`'s branch discriminator — see `crossfadeStateSwap`. Covers both the
/// pre-view-model placeholder and `gridContent`'s own initial-load placeholder under one
/// `.skeleton` case (they render identically), so the crossfade fires once, at the outer swap
/// point, rather than needing a second wrap inside `gridContent`.
private enum LibraryContentPhase: Hashable {
    case skeleton
    case failed
    case empty
    case loaded
}

struct LibraryGridView: View {
    let scope: LibraryScope
    let title: String
    /// The Jellyfin session backing this grid. The grid is Jellyfin-only — SMB shares route to
    /// `SMBBrowseView` from the sidebar/list, never here — so the session drives both the repo
    /// (`mediaRepoFactory(session)`) and per-tile detail pushes (via `ItemNavigator`).
    let session: Session

    /// A server collection (the common case — sidebar tab or Library-list drill-down).
    init(collection: MediaCollection, session: Session) {
        self.scope = .collection(collection.id)
        self.title = collection.name
        self.session = session
    }

    /// The cross-library Favorites grid (movies + shows merged) — a cross-Jellyfin-library grid.
    init(scope: LibraryScope, title: String, session: Session) {
        self.scope = scope
        self.title = title
        self.session = session
    }

    @Environment(AppDependencies.self) private var deps
    @Environment(\.appIdiom) private var idiom
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Jellyfin items carry 2:3 portrait posters; this drives BOTH the tile aspect ratio and the
    /// column count so the grid, its first-load placeholder, and the load-more strip stay in
    /// lockstep. (SMB's 16:9 landscape wall lives in `SMBBrowseView`, not here.)
    private var columns: Int { AppLayout.posterGridColumns(idiom: idiom) }
    @State private var viewModel: LibraryGridViewModel?

    var body: some View {
        Group {
            if let vm = viewModel {
                gridContent(vm: vm)
            } else {
                LibraryGridLoadingPlaceholder(columns: columns)
            }
        }
        // iOS-only crossfade of the whole skeleton→loaded/failed/empty swap; see
        // `crossfadeStateSwap`. Applied here, INSIDE the chrome modifiers below (navigationTitle,
        // toolbar, `.task`, …) so those stay on a stable outer node — a phase flip must not
        // re-fire `loadViewModel()`'s `.task` or tear down navigation/toolbar state. tvOS hard-cuts
        // as before.
        .crossfadeStateSwap(contentPhase)
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
        .task { await loadViewModel() }
        // Auto-recover the full-screen error when the network returns (or the app foregrounds
        // online). Gated on `isStalled` (failed AND no items) so a loaded grid — and the
        // stale-content refresh banner, which keeps its own "Try again" — are untouched.
        .recoversFromOffline(isStalled: viewModel?.isStalled ?? false) { await viewModel?.load() }
    }

    /// `crossfadeStateSwap`'s discriminator for `body`'s Group. `.loaded` covers BOTH the real
    /// grid and the "load more" strip beneath it — a background page fetch doesn't move this
    /// (only `isInitialLoad`/failed/empty do), so it can't compound with the grid's own
    /// `staleWhileRevalidate` dim on a sort/filter refetch (that keeps `vm.state == .loaded`
    /// throughout).
    private var contentPhase: LibraryContentPhase {
        guard let vm = viewModel else { return .skeleton }
        if isInitialLoad(vm) { return .skeleton }
        if case .failed = vm.state, vm.items.isEmpty { return .failed }
        if showsEmptyState(vm) { return .empty }
        return .loaded
    }

    /// One-shot view-model construction for the `.task`: build the repo-backed model and
    /// kick the first page. Idempotent — a `.task` re-fire (server switch) with the model
    /// already present is a no-op.
    private func loadViewModel() async {
        guard viewModel == nil else { return }
        let repo = await deps.mediaRepoFactory(session)
        let vm = LibraryGridViewModel(repo: repo, scope: scope)
        viewModel = vm
        await vm.load()
    }

    @ViewBuilder
    private func gridContent(vm: LibraryGridViewModel) -> some View {
        if isInitialLoad(vm) {
            LibraryGridLoadingPlaceholder(columns: columns)
        } else if case .failed(let message) = vm.state, vm.items.isEmpty {
            StatusStateView.failure("Couldn't load \(title)", message: message)
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
    private func showsEmptyState(_ vm: LibraryGridViewModel) -> Bool {
        vm.items.isEmpty && vm.state == .loaded && !vm.isRefreshing
    }

    @ViewBuilder
    private var emptyState: some View {
        if case .favorites = scope {
            StatusStateView(
                title: "No Favorites",
                systemImage: "heart",
                message: "Movies and shows you favorite will show up here."
            )
        } else {
            StatusStateView(
                title: "No Items",
                systemImage: "rectangle.stack",
                message: "Nothing in \(title) matches the current genre."
            )
        }
    }

    /// Full-screen placeholder only on the very first load — while genres are still
    /// in flight. Sort/filter/genre changes reload the grid but keep the header controls.
    private func isInitialLoad(_ vm: LibraryGridViewModel) -> Bool {
        vm.items.isEmpty && (vm.state == .idle || (vm.state == .loading && vm.isLoadingGenres))
    }

    private func refreshErrorBanner(message: String, vm: LibraryGridViewModel) -> some View {
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
    private func gridScrollContent(vm: LibraryGridViewModel) -> some View {
        if vm.items.isEmpty, vm.state == .loading {
            AdaptivePosterGridLoadingSkeleton(tileCount: columns * 3, fixedColumns: columns)
        } else {
            MediaGrid(
                items: vm.items,
                fixedColumns: columns,
                onAppearLast: { Task { await vm.loadMore() } }
            ) { item in
                // Jellyfin tiles browse-first: ItemNavigator pushes detail, wearing the
                // `.tvPosterButton()` poster focus treatment.
                ItemNavigator(item: item, session: session) { jellyfinTile(for: item, session: session) }
            }
            // Stale-while-revalidate dim → crossfade during the sort/filter/genre API
            // round-trip (shared with the Home shelves so the two never drift).
            .staleWhileRevalidate(isRefreshing: vm.isRefreshing, reduceMotion: reduceMotion)
            if vm.isLoadingMore {
                AdaptivePosterGridLoadingSkeleton(tileCount: columns, fixedColumns: columns)
                    .padding(.vertical, Space.s12)
            }
        }
    }

    /// Centered Genre + Sort control row — tvOS only, living INSIDE the scroll content (see
    /// `gridContent`) so the focus engine can scroll back up to it. Holds a stable height across
    /// loading → loaded so the grid below never shifts; Genre collapses out when the library has no
    /// genres. Horizontal inset comes from the scroll view's `contentMargins`, not local padding.
    @ViewBuilder
    private func headerControls(vm: LibraryGridViewModel) -> some View {
        // No `GlassEffectContainer` here: this row only renders on tvOS (iOS puts the
        // controls in the nav bar), and on tvOS the container re-renders the native button
        // glass in its own layer — glyphs drift off the discs and the glass desyncs from
        // the system focus lift (pixel-measured in the "Action row parity" preview).
        let hasGenreSlot = vm.isLoadingGenres || !vm.availableGenres.isEmpty
        // Split the row into two equal halves so the pair is symmetric about the screen's
        // center axis: Genre hugs the trailing edge of the left half, Sort the leading edge of
        // the right half, so the gap between them stays centered however their content-sized
        // widths differ. With no genres the left half collapses to zero width and Sort centers
        // across the full row — a lone control reads best centered, not pinned off-axis.
        HStack(spacing: hasGenreSlot ? Space.s12 : 0) {
            genreHeaderSlot(vm: vm)
                .frame(maxWidth: hasGenreSlot ? .infinity : 0, alignment: .trailing)
            sortMenu(vm: vm)
                .frame(maxWidth: .infinity, alignment: hasGenreSlot ? .leading : .center)
        }
        .padding(.top, Space.s8)
        // Clear the first poster row at 10-foot distance: 8pt crowded the chips against the grid
        // and let their focus lift collide with row 1's. iOS carries these controls in the nav bar,
        // never in-content, so this gap is tvOS-only by construction. Keep in sync with the
        // loading placeholder's header padding so the skeleton→real swap stays shift-free.
        .padding(.bottom, Space.s30)
        // The two chips sit just inside the center axis, so they only cover the middle columns. The tvOS focus
        // engine searches straight UP from the focused poster, so from the outer columns there's no
        // chip in line and pressing Up does nothing. `focusSection()` turns the row's full width
        // into one focus target that diverts to the nearest chip — Up from ANY column now reaches
        // Genre/Sort. (Apple's tvOS catalog sample applies it for this exact above-the-fold case.)
        .tvFocusSection()
        .animation(reduceMotion ? nil : .smooth, value: vm.isLoadingGenres)
    }

    /// The header's left slot: the Genre menu once genres load, a skeleton capsule while
    /// they're still in flight, or nothing when the library has no genres (its equal-width
    /// half then collapses and Sort centers — see `headerControls`).
    @ViewBuilder
    private func genreHeaderSlot(vm: LibraryGridViewModel) -> some View {
        if vm.isLoadingGenres {
            Capsule().fill(Color.fill).frame(width: LibraryHeaderChip.genreWidth, height: LibraryHeaderChip.height)
        } else if !vm.availableGenres.isEmpty {
            genreMenu(vm: vm)
        }
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
    /// menu). Shares `libraryHeaderMenu` with Sort so the two chips are styled identically;
    /// a selected genre flips the resting monochrome tint to the filled `chipSelectedFill`.
    private func genreMenu(vm: LibraryGridViewModel) -> some View {
        libraryHeaderMenu(
            title: vm.selectedGenre ?? "Genre",
            systemImage: "theatermasks",
            activeTint: vm.selectedGenre != nil ? Color.chipSelectedFill : nil,
            accessibilityLabel: "Genre"
        ) {
            genrePicker(vm: vm)
        }
    }

    /// Single-select genre filter, collapsed from a scrolling chip bar into one menu: the inline
    /// `Picker` gives each genre the system's leading checkmark, with "All Genres" to clear.
    /// Shared by the tvOS chip and the combined sort menu's submenu (iPhone/iPad).
    @ViewBuilder
    private func genrePicker(vm: LibraryGridViewModel) -> some View {
        @Bindable var vm = vm
        Picker("Genre", selection: $vm.selectedGenre) {
            Text("All Genres").tag(String?.none)
            ForEach(vm.availableGenres, id: \.self) { genre in
                Text(genre).tag(String?.some(genre))
            }
        }
        .pickerStyle(.inline)
    }

    /// Inline-header Sort menu — tvOS-only like `genreMenu` (Genre stays its own chip
    /// there, so this menu is sort-only). No `activeTint`: Sort has no selected state, so
    /// it rests on the same monochrome `Color.label` tint as an unselected Genre.
    private func sortMenu(vm: LibraryGridViewModel) -> some View {
        libraryHeaderMenu(
            title: "Sort",
            systemImage: "arrow.up.arrow.down",
            accessibilityLabel: "Sort"
        ) {
            sortPicker(vm: vm)
        }
    }

    /// The tvOS sort menu body: same human-language direction labels as the iOS
    /// bridged menu (one vocabulary — `LibrarySortVocabulary`), but as an inline
    /// picker — the tile row is a touch-menu affordance the tvOS focus engine
    /// doesn't render. Genre stays its own header chip there.
    @ViewBuilder
    private func sortPicker(vm: LibraryGridViewModel) -> some View {
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
    private func jellyfinTile(for item: Item, session: Session) -> some View {
        MediaTile(
            title: item.displayTitle,
            imageRef: image(for: item),
            session: session,
            watched: .init(item),
            aspectRatio: MediaImage.poster,
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

/// Shared label for the tvOS header menus (Genre, Sort) so the two read identically.
/// Bare — the enclosing Menu wears the native `.glass` style, which owns the capsule,
/// metrics, and label color: the label rests as `Color.label` over translucent glass
/// (legible), and the focused platter brightens without recoloring it. A forced
/// `foregroundStyle` would fight that, so leave it off. Selection shows via the menu's tint.
private func libraryHeaderChipLabel(_ title: String, systemImage: String) -> some View {
    Label(title, systemImage: systemImage)
        .labelStyle(.titleAndIcon)
        .font(.subheadline.weight(.medium))
}

/// Shared builder for the tvOS in-content header menus (Genre + Sort) so the pair is styled
/// identically. Both wear the native `.glass` style — translucent Liquid Glass at rest,
/// brightening on focus — with a `Color.label` resting tint (the value `RootView` pins
/// app-wide), so the label reads legibly over the frosted capsule. A header passes a non-nil
/// `activeTint` (Genre's `chipSelectedFill`) only to flip to the filled "active filter" look.
///
/// NOT `.bordered`: on tvOS its resting platter takes the tint AND it draws the label in that
/// same tint, so under our monochrome `Color.label` the two collapse to one color and the
/// label is invisible until focus inverts it. `.glass` keeps the label and capsule distinct.
///
/// The resting tint is set EXPLICITLY, not left to inherit: Genre used to clear it with
/// `.tint(nil)`, which reset to the system accent and rendered a visibly different color
/// from Sort (which inherited `Color.label`) — the asymmetry this fixes. Passing the tint
/// unconditionally also keeps the modifier identity stable, so toggling a genre never tears
/// down the Menu and drops tvOS focus.
private func libraryHeaderMenu<Content: View>(
    title: String,
    systemImage: String,
    activeTint: Color? = nil,
    accessibilityLabel: String,
    @ViewBuilder content: () -> Content
) -> some View {
    Menu {
        content()
    } label: {
        libraryHeaderChipLabel(title, systemImage: systemImage)
    }
    .buttonStyle(.glass)
    .tint(activeTint ?? Color.label)
    .accessibilityLabel(accessibilityLabel)
}

/// Full-screen first-load placeholder: genre-pill row above a poster-grid skeleton,
/// laid out to match the loaded grid so content doesn't shift in when it arrives. A
/// standalone view (not a `@ViewBuilder` on the grid) so it owns its own body
/// invalidation and renders identically from both the pre-VM and initial-load branches.
private struct LibraryGridLoadingPlaceholder: View {
    /// Column count comes from `LibraryGridView` so the placeholder lays out the exact poster grid
    /// the loaded content will — no shift when the real grid swaps in.
    let columns: Int

    @Environment(\.appIdiom) private var idiom

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                // Match the loaded grid's tvOS in-content header geometry (two centered capsules) so
                // the swap to the real Genre/Sort controls is shift-free. iPhone/iPad carry those in
                // the nav bar, not the content, so they skip the placeholder capsules. Horizontal
                // inset comes from `contentMargins`, like the header itself.
                if idiom == .tv {
                    // Equal halves matching `headerControls`' loading state (both slots present)
                    // so the skeleton→real-controls swap stays symmetric and shift-free.
                    HStack(spacing: Space.s12) {
                        Capsule().fill(Color.fill).frame(width: LibraryHeaderChip.genreWidth, height: LibraryHeaderChip.height)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                        Capsule().fill(Color.fill).frame(width: LibraryHeaderChip.sortWidth, height: LibraryHeaderChip.height)
                            .frame(maxWidth: .infinity, alignment: .leading)
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
}

#if DEBUG
/// Genre ⇄ Sort header parity + center-axis symmetry. The row splits into two equal halves —
/// Genre trailing-aligned in the left, Sort leading-aligned in the right — so the gap between
/// the pair stays centered on the axis (red hairline) however their content widths differ.
/// Both share the monochrome `Color.label` resting tint; Genre flips to `chipSelectedFill`
/// when a genre is active (second row). The third row is the no-genre case: Sort centers
/// alone on the same axis. Wrapped in `.tint(Color.label)` to mirror RootView's global tint.
#Preview("Header parity + axis", traits: .fixedLayout(width: 900, height: 470)) {
    VStack(spacing: Space.s40) {
        HStack(spacing: Space.s12) {
            libraryHeaderMenu(title: "Genre", systemImage: "theatermasks", accessibilityLabel: "Genre") { Text("Genres") }
                .frame(maxWidth: .infinity, alignment: .trailing)
            libraryHeaderMenu(title: "Sort", systemImage: "arrow.up.arrow.down", accessibilityLabel: "Sort") { Text("Sort") }
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        HStack(spacing: Space.s12) {
            libraryHeaderMenu(title: "Action", systemImage: "theatermasks", activeTint: Color.chipSelectedFill, accessibilityLabel: "Genre") { Text("Genres") }
                .frame(maxWidth: .infinity, alignment: .trailing)
            libraryHeaderMenu(title: "Sort", systemImage: "arrow.up.arrow.down", accessibilityLabel: "Sort") { Text("Sort") }
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        libraryHeaderMenu(title: "Sort", systemImage: "arrow.up.arrow.down", accessibilityLabel: "Sort") { Text("Sort") }
            .frame(maxWidth: .infinity, alignment: .center)
    }
    .padding(.horizontal, 48)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .overlay(alignment: .center) {
        Rectangle().fill(Color.red.opacity(0.55)).frame(width: 1)
    }
    .background(Color.background)
    .tint(Color.label)
}
#endif
