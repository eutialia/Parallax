import SwiftUI
import ParallaxJellyfin
import ParallaxCore

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

/// One server collection's poster grid. Always SINGLE-server: the sidebar tab and the Library-list
/// drill-down both open exactly one library. The cross-server Favorites wall is `FavoritesView`,
/// which stacks one `LibraryGridViewModel` per server under its own header rather than merging them.
struct LibraryGridView: View {
    let scope: LibraryScope
    let title: String
    /// The Jellyfin session backing this grid. The grid is Jellyfin-only — SMB shares route to
    /// `SMBBrowseView` from the sidebar/list, never here — so the session drives both the repo
    /// (`mediaRepoFactory(session)`) and per-tile detail pushes (via `ItemNavigator`).
    let session: Session

    init(collection: MediaCollection, session: Session) {
        self.scope = .collection(collection.id)
        self.title = collection.name
        self.session = session
    }

    @Environment(AppDependencies.self) private var deps
    @Environment(UserDataActions.self) private var userDataActions
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
        let vm = LibraryGridViewModel(repo: repo, source: .jellyfin(session.id), scope: scope, userDataActions: userDataActions)
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
            // tvOS hosts this grid only as a sidebar tab ROOT, so it always takes the root-chrome
            // bypass — the wall rests at title-safe like every other wall instead of 60pt lower
            // under the collapsed-pill band. See `mediaWallContentMargins`.
            .mediaWallContentMargins(tvRootChromeBypass: true)
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

    /// Loaded but nothing to show — a collection filtered down to nothing by the genre picker.
    private func showsEmptyState(_ vm: LibraryGridViewModel) -> Bool {
        vm.items.isEmpty && vm.state == .loaded && !vm.isRefreshing
    }

    private var emptyState: some View {
        StatusStateView(
            title: "No Items",
            systemImage: "rectangle.stack",
            message: "Nothing in \(title) matches the current genre."
        )
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
    /// `gridContent`) so the focus engine can scroll back up to it. Shared with the Favorites wall,
    /// which drives the identical controls from its own coordinator.
    private func headerControls(vm: LibraryGridViewModel) -> some View {
        LibraryHeaderControls(
            sortField: vm.sortField,
            sortDirection: vm.sortDirection,
            selectedGenre: vm.selectedGenre,
            availableGenres: vm.availableGenres,
            isLoadingGenres: vm.isLoadingGenres,
            onSelectField: { vm.sortField = $0 },
            onSelectDirection: { vm.sortDirection = $0 },
            onSelectGenre: { vm.selectedGenre = $0 }
        )
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
                    LibraryHeaderControlsSkeleton()
                }
                AdaptivePosterGridLoadingSkeleton(tileCount: columns * 3, fixedColumns: columns)
            }
        }
        .scrollDisabled(true)
        // The IDENTICAL margins + root-chrome bypass as the loaded grid (`gridContent`), so the
        // first poster row lands at the same y when the skeleton swaps out — no jump on tvOS load.
        .mediaWallContentMargins(tvRootChromeBypass: true)
    }
}
