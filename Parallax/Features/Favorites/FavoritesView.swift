import SwiftUI
import ParallaxCore
import ParallaxJellyfin

/// `FavoritesView.body`'s branch discriminator — see `crossfadeStateSwap`.
private enum FavoritesContentPhase: Hashable {
    case skeleton
    case failed
    case empty
    case loaded
}

/// Favorites across every signed-in Jellyfin server, one titled section per server.
///
/// The sectioning rationale lives on `FavoritesViewModel`. Structurally this is N independent
/// library grids stacked in one scroll view, which is why it needs no merge logic: each section
/// renders its own server's items in its own server's order, and each paginates itself as you reach
/// its end (the grids are lazy, so a section below the fold hasn't fetched a second page yet).
///
/// A single server still gets a section header. Suppressing it would make the screen silently
/// change shape when a second server is added — and the header is the thing that explains why the
/// sort restarts partway down, so it has to be present whenever it's true, not only when it's
/// crowded.
struct FavoritesView: View {
    @Environment(AppDependencies.self) private var deps
    @Environment(AppRouter.self) private var router
    @Environment(UserDataActions.self) private var userDataActions
    @Environment(\.appIdiom) private var idiom
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var viewModel = FavoritesViewModel()

    /// Jellyfin items carry 2:3 portrait posters; this drives BOTH the tile aspect ratio and the
    /// column count so every section, its skeleton, and its load-more strip stay in lockstep.
    private var columns: Int { AppLayout.posterGridColumns(idiom: idiom) }

    var body: some View {
        content
            .crossfadeStateSwap(contentPhase)
            #if !os(tvOS)
            .navigationTitle("Favorites")
            .navigationBarTitleDisplayMode(.inline)
            // One combined Sort menu in the nav bar, exactly as a library grid has. Unconditional
            // (not gated on loaded state): a toolbar item inserted mid-push doesn't render until
            // the transition settles, so the button was blinking in late.
            .toolbar { favoritesControlsToolbar }
            #endif
            .itemDetailNavigation()
            .screenFloor()
            // Re-fired when the source set changes, so signing into a second server adds its
            // section without a relaunch — the same token both navigation roots key on.
            .task(id: router.libraryReloadToken) {
                await viewModel.load(
                    sessions: await deps.serverStore.sessions,
                    repoFactory: deps.mediaRepoFactory,
                    userDataActions: userDataActions
                )
            }
            // Repair only the sections that failed when the network returns; the servers already on
            // screen are never re-pulled.
            .recoversFromOffline(isStalled: !viewModel.failedSections.isEmpty) {
                await viewModel.reloadFailedSections()
            }
    }

    private var contentPhase: FavoritesContentPhase {
        if viewModel.isInitialLoad { return .skeleton }
        if viewModel.hasFailedEntirely { return .failed }
        if viewModel.isEmpty { return .empty }
        return .loaded
    }

    @ViewBuilder
    private var content: some View {
        switch contentPhase {
        case .skeleton:
            FavoritesLoadingPlaceholder(columns: columns)
        case .failed:
            StatusStateView.failure(
                "Couldn't load Favorites",
                message: "Parallax couldn't reach your servers."
            )
        case .empty:
            StatusStateView(
                title: "No Favorites",
                systemImage: "heart",
                message: "Movies and shows you favorite will show up here."
            )
        case .loaded:
            wall
        }
    }

    private var wall: some View {
        ScrollView {
            // tvOS: the last row of section N carries the same focus lift as GridSection's own
            // header gap (see `AppLayout.focusSafeHeaderGap`'s doc comment for the lift arithmetic).
            VStack(alignment: .leading, spacing: AppLayout.focusSafeSectionGap(idiom: idiom)) {
                // tvOS: Genre + Sort scroll WITH the wall (in-content) so the focus engine can climb
                // back up to them. iPhone/iPad carry the controls in the nav bar instead.
                if idiom == .tv {
                    LibraryHeaderControls(
                        sortField: viewModel.sortField,
                        sortDirection: viewModel.sortDirection,
                        selectedGenre: viewModel.selectedGenre,
                        availableGenres: viewModel.availableGenres,
                        isLoadingGenres: viewModel.isLoadingGenres,
                        onSelectField: { viewModel.sortField = $0 },
                        onSelectDirection: { viewModel.sortDirection = $0 },
                        onSelectGenre: { viewModel.selectedGenre = $0 }
                    )
                }
                ForEach(viewModel.visibleSections) { section in
                    self.section(section)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // tvOS hosts Favorites only as a sidebar tab ROOT, so it always takes the root-chrome
        // bypass — same resting geometry as the library grid and SMB walls. See
        // `mediaWallContentMargins`.
        .mediaWallContentMargins(tvRootChromeBypass: true)
    }

    @ViewBuilder
    private func section(_ section: FavoritesViewModel.Section) -> some View {
        let grid = section.grid
        GridSection(title: section.title, count: grid.isStalled ? nil : grid.items.count) {
            if grid.isStalled {
                // Named, not swallowed: with two servers configured, silently dropping the
                // unreachable one's section would look like the user simply has fewer favorites
                // than they remember. The rest of the wall stays usable.
                SectionFailureRow(message: "Couldn't reach \(section.title).") {
                    Task { await grid.load() }
                }
            } else {
                MediaGrid(
                    items: grid.items,
                    fixedColumns: columns,
                    // Each section pages itself. Sections below the fold haven't materialized their
                    // last tile yet, so they don't fetch until you scroll into them.
                    onAppearLast: { Task { await grid.loadMore() } }
                ) { item in
                    // Each section carries its OWN session: the wall mixes servers, so a
                    // screen-level session would build one server's poster URL against another's
                    // host and bearer token. Sectioning makes this trivially correct — every tile
                    // in a section belongs to that section's server, by construction.
                    ItemNavigator(item: item, session: section.session) {
                        MediaTile(
                            title: item.displayTitle,
                            imageRef: image(for: item),
                            session: section.session,
                            watched: .init(item),
                            aspectRatio: MediaImage.poster,
                            maxImageWidth: 600
                        )
                    }
                }
                // Stale-while-revalidate dim → crossfade during the sort/genre round-trip, shared
                // with the library grid and Home shelves so the three never drift.
                .staleWhileRevalidate(isRefreshing: grid.isRefreshing, reduceMotion: reduceMotion)
                if grid.isLoadingMore {
                    AdaptivePosterGridLoadingSkeleton(tileCount: columns, fixedColumns: columns)
                        .padding(.vertical, Space.s12)
                }
            }
        }
    }

    private func image(for item: Item) -> ImageRef? {
        switch item {
        case .movie(let m): return m.imageRef(.primary)
        case .series(let s): return s.imageRef(.primary)
        case .episode(let e): return e.imageRef(.primary)
        }
    }

    #if !os(tvOS)
    @ToolbarContentBuilder
    private var favoritesControlsToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            LibrarySortMenuButton(
                sortField: viewModel.sortField,
                sortDirection: viewModel.sortDirection,
                selectedGenre: viewModel.selectedGenre,
                availableGenres: viewModel.availableGenres,
                isEnabled: !viewModel.sections.isEmpty,
                onSelectField: { viewModel.sortField = $0 },
                onSelectDirection: { viewModel.sortDirection = $0 },
                onSelectGenre: { viewModel.selectedGenre = $0 }
            )
        }
    }
    #endif
}

/// A section whose server couldn't be reached, with its own retry. Deliberately compact — it sits
/// inside a wall of working content, so it's a line, not a full-screen takeover.
private struct SectionFailureRow: View {
    let message: String
    let onRetry: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.s8) {
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.subheadline)
                .foregroundStyle(Color.secondaryLabel)
                .lineLimit(2)
            Spacer(minLength: Space.s8)
            Button("Try again", action: onRetry)
                .font(.subheadline.weight(.semibold))
        }
        .padding(.vertical, Space.s8)
        .accessibilityElement(children: .combine)
    }
}

#if DEBUG
/// The wall's shape with two servers: a titled section per server, each with its own count, the
/// second starting a fresh sort run below the first. Poster skeletons stand in for tiles — this
/// preview is about the section rhythm (header placement, the gap between sections, column
/// alignment across them), which is the only thing sectioning changes.
///
/// The gap reads the SAME token the wall does (`AppLayout.focusSafeSectionGap`) rather than a
/// hardcoded copy — a preview whose whole subject is the inter-section rhythm has to move when the
/// wall's rhythm moves, or it starts certifying a layout the app no longer ships.
#Preview("Favorites · two servers", traits: .fixedLayout(width: 540, height: 980)) {
    ScrollView {
        VStack(alignment: .leading, spacing: AppLayout.focusSafeSectionGap(idiom: .compact)) {
            GridSection(title: "Living Room", count: 6) {
                AdaptivePosterGridLoadingSkeleton(tileCount: 6, fixedColumns: 3)
            }
            GridSection(title: "Basement NAS", count: 3) {
                AdaptivePosterGridLoadingSkeleton(tileCount: 3, fixedColumns: 3)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .contentMargins(.horizontal, AppLayout.contentHMargin(idiom: .compact), for: .scrollContent)
    .screenFloor()
}

/// Parity guard: the first-load placeholder (left) beside the loaded two-server wall
/// (right), same fixtures as the preview above. The placeholder has to open with a section
/// header, or the wall's first tile row jumps down by the header's height on arrival. Measure
/// with `render-ruler.py --pt-width 1080 --scan-col 0.25,0.75` — the first tile run must start
/// on the same row in both halves. (Lives here, not in `LoadingSkeleton.swift`, because
/// `FavoritesLoadingPlaceholder` is this screen's private view.)
#Preview("Favorites skeleton ↔ wall", traits: .fixedLayout(width: 1080, height: 980)) {
    HStack(alignment: .top, spacing: 0) {
        FavoritesLoadingPlaceholder(columns: 3)
            .frame(width: 540)
            .environment(\.appIdiom, .compact)
        ScrollView {
            VStack(alignment: .leading, spacing: AppLayout.focusSafeSectionGap(idiom: .compact)) {
                GridSection(title: "Living Room", count: 6) {
                    AdaptivePosterGridLoadingSkeleton(tileCount: 6, fixedColumns: 3)
                }
                GridSection(title: "Basement NAS", count: 3) {
                    AdaptivePosterGridLoadingSkeleton(tileCount: 3, fixedColumns: 3)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollDisabled(true)
        .mediaWallContentMargins(tvRootChromeBypass: true)
        .frame(width: 540)
        .environment(\.appIdiom, .compact)
    }
    .frame(maxHeight: .infinity, alignment: .top)
    // Black so the ruler script's run-lengths separate (see `SkeletonParity`).
    .background(.black)
    .preferredColorScheme(.dark)
}
#endif

/// First-load placeholder: one section header + poster skeleton, laid out to match a loaded section
/// so content doesn't shift when it arrives.
///
/// It renders the wall's real containers — the same `focusSafeSectionGap` stack and a real
/// `GridSection`, redacted so the server-name header reads as a bar. Without the header the first
/// tile row sat 37pt above where the wall put it (render-measured); the wall's own preview
/// had shown the correct shape all along.
private struct FavoritesLoadingPlaceholder: View {
    let columns: Int

    @Environment(\.appIdiom) private var idiom

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppLayout.focusSafeSectionGap(idiom: idiom)) {
                if idiom == .tv {
                    LibraryHeaderControlsSkeleton()
                }
                // A stand-in server name: redaction masks the glyphs but keeps the line box, so
                // this only sets the bar's WIDTH — real names land anywhere near it.
                GridSection(title: "Media Server", count: nil) {
                    AdaptivePosterGridLoadingSkeleton(tileCount: columns * 3, fixedColumns: columns, shimmer: false)
                }
                .redacted(reason: .placeholder)
            }
            // ONE shimmer clock for the whole placeholder — the header bar and the tvOS chip row
            // sweep with the tiles instead of sitting static beside them, which is why the grid
            // goes in with `shimmer: false`.
            .skeletonShimmer()
        }
        .scrollDisabled(true)
        // The IDENTICAL margins + root-chrome bypass as the loaded wall.
        .mediaWallContentMargins(tvRootChromeBypass: true)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading favorites")
    }
}
