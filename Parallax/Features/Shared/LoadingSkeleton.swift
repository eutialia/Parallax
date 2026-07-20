import SwiftUI

// MARK: - Primitives

/// Monochrome placeholder block. The shimmer is driven once per screen by the enclosing
/// `.skeletonShimmer()` (a single shared clock), so the block itself stays static.
struct SkeletonBlock: View {
    var cornerRadius: CGFloat = Radius.tile
    var height: CGFloat? = nil

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(Color.fill)
            .frame(height: height)
            .frame(maxWidth: .infinity)
            .accessibilityHidden(true)
    }
}

/// One shimmer sweep for an entire skeleton screen: a single `TimelineView` clock drives
/// one light band masked to the whole placeholder subtree. This replaces a per-block
/// `TimelineView` (a 12-tile grid otherwise ran 12 display-link drivers); the blocks it
/// masks are static, so each frame only repositions the one gradient. Static under
/// Reduce Motion. Apply ONCE at the top of a skeleton screen, never per block.
struct SkeletonShimmerModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The masked subtree's width, captured via `onGeometryChange` instead of a
    /// `GeometryReader` so the overlay sizes to `content` (not the other way round) and
    /// the closure re-runs only on a real resize — the `TimelineView` already drives the
    /// per-frame sweep. Zero until the first layout pass (band collapses to nothing, no
    /// shimmer) — one frame, invisible.
    @State private var width: CGFloat = 0

    func body(content: Content) -> some View {
        if reduceMotion {
            content
        } else {
            content.overlay {
                TimelineView(.animation) { context in
                    let period: TimeInterval = 1.35
                    let phase = context.date.timeIntervalSinceReferenceDate
                        .truncatingRemainder(dividingBy: period) / period
                    let band = width * 0.35
                    LinearGradient(
                        colors: [.clear, Color.white.opacity(0.28), .clear],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: band)
                    // Full-height band pinned to the leading edge, then slid across — the
                    // layout `GeometryReader` placed at top-leading and filled by default.
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    .offset(x: (width + band) * phase - band)
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
                .allowsHitTesting(false)
                .mask(content)
            }
        }
    }
}

extension View {
    /// Apply once at the top of a skeleton screen (not per block) — see `SkeletonShimmerModifier`.
    func skeletonShimmer() -> some View {
        modifier(SkeletonShimmerModifier())
    }
}

// MARK: - Tiles & rows

/// Tile placeholder — mirrors `MediaTile`. Poster grids show the bare artwork block; SMB landscape
/// grids set `showsMetadata` to reserve the under-thumbnail filename + duration row so the
/// loading→loaded swap doesn't shift the grid.
struct MediaTileSkeleton: View {
    var aspectRatio: CGFloat = MediaImage.poster
    var showsMetadata: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: MediaTile.metadataGap) {
            SkeletonBlock(cornerRadius: Radius.tile)
                .aspectRatio(aspectRatio, contentMode: .fit)
            if showsMetadata {
                // Two stub lines reserving the real MediaTile.metadataRow's rendered height (a
                // .subheadline title line + gap + a .caption2 line) so the loading→loaded swap
                // doesn't shift the grid. Sizes come from MediaTile's shared statics — compiler-
                // coupled to the real row, not comment-coupled, so the two can't silently drift.
                VStack(alignment: .leading, spacing: MediaTile.metadataLineSpacing) {
                    SkeletonBlock(cornerRadius: 4, height: MediaTile.metadataTitleStubHeight)
                    SkeletonBlock(cornerRadius: 4, height: MediaTile.metadataDetailStubHeight)
                        .frame(width: 56)
                }
            }
        }
    }
}

struct MetadataRowSkeleton: View {
    let tileWidth: CGFloat
    var aspectRatio: CGFloat = MediaImage.landscape

    @Environment(\.appIdiom) private var idiom
    @State private var rowWidth: CGFloat = 0

    /// Enough tiles to fill the row edge-to-edge plus one peeking past the trailing edge
    /// (the cue that the real shelf scrolls). Derived from the live width — `onGeometryChange`
    /// rather than a fixed count, so it fits any screen: a fixed 7 underfills an iPad in
    /// landscape and overflows an iPhone. `.up + 1` errs toward overflow, which the disabled
    /// ScrollView clips, so the row never falls short of the edge.
    private var tileCount: Int {
        guard rowWidth > 0 else { return 4 }
        return Int((rowWidth / (tileWidth + Space.s12)).rounded(.up)) + 1
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s8) {
            // Matches MetadataRow's `.title2.bold` header height so the loading→loaded
            // swap doesn't jolt the shelf down.
            SkeletonBlock(cornerRadius: 6, height: 26)
                .frame(width: 168)
                .padding(.horizontal, AppLayout.contentHMargin(idiom: idiom))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: Space.s12) {
                    ForEach(0..<tileCount, id: \.self) { _ in
                        MediaTileSkeleton(aspectRatio: aspectRatio)
                            .frame(width: tileWidth)
                    }
                }
                .padding(.horizontal, AppLayout.contentHMargin(idiom: idiom))
            }
            .scrollDisabled(true)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { rowWidth = $0 }
    }
}

// MARK: - Screen layouts

struct HomeLoadingSkeleton: View {
    @Environment(\.appIdiom) private var idiom

    var body: some View {
        LazyVStack(alignment: .leading, spacing: Space.s30) {
            // Hero placeholder bleeds full-width like the real carousel; shelves stay title-safe.
            SkeletonBlock(cornerRadius: 0)
                .aspectRatio(
                    HeroMetrics.bandAspectRatio(regularWidth: idiom.usesLandscapeHeroBand),
                    contentMode: .fit
                )
            VStack(alignment: .leading, spacing: Space.s30) {
                MetadataRowSkeleton(tileWidth: HomeShelf.tileWidth, aspectRatio: MediaImage.poster)
                MetadataRowSkeleton(tileWidth: HomeShelf.tileWidth, aspectRatio: MediaImage.poster)
            }
            .tvContentInset()
        }
        .padding(.bottom, Space.s30)
        .skeletonShimmer()
    }
}

struct PosterGridLoadingSkeleton: View {
    let columns: Int
    let rows: Int

    @Environment(\.appIdiom) private var idiom

    var body: some View {
        // Same idiom-aware gaps as the loaded search grid (JellyfinSearchResultsView) —
        // hardcoded 12/18 here would visibly re-space the whole grid on the skeleton→results
        // swap now that the loaded side uses the 40pt tvOS focus-clearance tokens.
        LazyVGrid(
            columns: posterGridColumns(
                fixedColumns: columns, columnMinWidth: 0,
                columnSpacing: AppLayout.posterGridColumnSpacing(idiom: idiom)
            ),
            spacing: AppLayout.posterGridRowSpacing(idiom: idiom)
        ) {
            ForEach(0..<(columns * rows), id: \.self) { _ in
                MediaTileSkeleton()
            }
        }
        // Horizontal = the shared content margin so the swap to the loaded
        // search grid (which insets by the same knob) is shift-free.
        .padding(.horizontal, AppLayout.contentHMargin(idiom: idiom))
        .padding(.vertical, Space.s18)
        .skeletonShimmer()
    }
}

struct AdaptivePosterGridLoadingSkeleton: View {
    let tileCount: Int
    var columnMinWidth: CGFloat = 140
    /// Fixed column count; when nil the grid adapts by `columnMinWidth`. Mirrors `MediaGrid`.
    var fixedColumns: Int? = nil
    /// Tile shape — `.poster` for Jellyfin grids, `.landscape` for SMB frame-grab grids, so the
    /// skeleton matches the loaded tiles and the swap stays shift-free.
    var aspectRatio: CGFloat = MediaImage.poster
    /// Reserve the under-thumbnail metadata row (SMB grids) so the swap to loaded tiles is shift-free.
    var showsMetadata: Bool = false

    @Environment(\.appIdiom) private var idiom

    var body: some View {
        let columns = posterGridColumns(
            fixedColumns: fixedColumns,
            columnMinWidth: columnMinWidth,
            columnSpacing: AppLayout.posterGridColumnSpacing(idiom: idiom)
        )
        LazyVGrid(columns: columns, spacing: AppLayout.posterGridRowSpacing(idiom: idiom)) {
            ForEach(0..<tileCount, id: \.self) { _ in
                MediaTileSkeleton(aspectRatio: aspectRatio, showsMetadata: showsMetadata)
            }
        }
        .skeletonShimmer()
    }
}

struct LibraryListLoadingSkeleton: View {
    @Environment(\.appIdiom) private var idiom

    var body: some View {
        // Mirror the loaded grid's column count AND spacing so the swap to real cards doesn't
        // shift them (tvOS uses the wider 40pt focus-safe gap; see `AppLayout.libraryListSpacing`).
        let columns = AppLayout.libraryListColumns(idiom: idiom)
        let gap = AppLayout.libraryListSpacing(idiom: idiom)
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: gap), count: columns),
            spacing: gap
        ) {
            ForEach(0..<(columns * 3), id: \.self) { _ in
                SkeletonBlock(cornerRadius: Radius.card)
                    .aspectRatio(MediaImage.landscape, contentMode: .fit)
            }
        }
        // Same all-edge inset as the loaded list (`LibraryListView`)
        // so the skeleton→cards swap doesn't shift.
        .padding(AppLayout.contentHMargin(idiom: idiom))
        .skeletonShimmer()
    }
}

/// Full-height library-list placeholder: column count tracks the size class and the
/// disabled `ScrollView` lets it fill the screen like the loaded grid. Shared by the
/// Library list, its bootstrap host, and the per-server task gate.
struct LibraryListLoadingPlaceholder: View {
    var body: some View {
        ScrollView {
            LibraryListLoadingSkeleton()
        }
        .scrollDisabled(true)
    }
}

struct DetailLoadingSkeleton: View {
    @Environment(\.appIdiom) private var idiom
    @Environment(\.horizontalSizeClass) private var hSize

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.s18) {
                SkeletonBlock(cornerRadius: 0)
                    .aspectRatio(
                        HeroMetrics.bandAspectRatio(regularWidth: idiom.usesLandscapeHeroBand),
                        contentMode: .fit
                    )
                VStack(alignment: .leading, spacing: Space.s12) {
                    SkeletonBlock(cornerRadius: 8, height: hSize == .regular ? 36 : 28)
                        .padding(.trailing, Space.s40)
                    SkeletonBlock(cornerRadius: 6, height: 16)
                        .frame(width: 200)
                    HStack(spacing: Space.s12) {
                        SkeletonBlock(cornerRadius: Radius.field, height: 44)
                            .frame(width: 108)
                        SkeletonBlock(cornerRadius: 22, height: 44)
                            .frame(width: 44)
                        SkeletonBlock(cornerRadius: 22, height: 44)
                            .frame(width: 44)
                    }
                }
                // The loaded hero foreground insets by HeroMetrics, not the
                // content margin — match it so the title/play block lands
                // where the real hero's does.
                .padding(.horizontal, HeroMetrics.foregroundHorizontalInset(idiom: idiom))
                .padding(.top, -Space.s60)
                .tvContentInset()

                VStack(alignment: .leading, spacing: Space.s8) {
                    ForEach(0..<4, id: \.self) { i in
                        SkeletonBlock(cornerRadius: 6, height: 14)
                            .padding(.trailing, CGFloat(40 + i * 18))
                    }
                }
                // The loaded detail body (overview, metadata lines) insets by
                // the shared content margin — keep the swap shift-free.
                .padding(.horizontal, AppLayout.contentHMargin(idiom: idiom))
                .tvContentInset()
            }
            .padding(.bottom, Space.s30)
            .skeletonShimmer()
        }
        .scrollDisabled(true)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading details")
    }
}

struct EpisodeListLoadingSkeleton: View {
    @Environment(\.appIdiom) private var idiom

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s22) {
            ForEach(0..<2, id: \.self) { _ in
                VStack(alignment: .leading, spacing: Space.s8) {
                    SkeletonBlock(cornerRadius: 6, height: 22)
                        .frame(width: 120)
                        .padding(.horizontal, AppLayout.contentHMargin(idiom: idiom))
                    ScrollView(.horizontal, showsIndicators: false) {
                        // `showsMetadata`: the season-row tiles now carry a title + time row BELOW the
                        // still (the one-text-region law moved the caption there), so the skeleton must
                        // reserve those lines or the load→loaded swap jumps. `.top`-aligned like the
                        // real `MetadataRow`.
                        HStack(alignment: .top, spacing: Space.s12) {
                            ForEach(0..<5, id: \.self) { _ in
                                MediaTileSkeleton(aspectRatio: MediaImage.landscape, showsMetadata: true)
                                    // Idiom-aware, like the loaded shelf: the tv tile is 280pt, and a
                                    // 240pt skeleton would make the whole row reflow on load there.
                                    .frame(width: AppLayout.seriesEpisodeTileWidth(idiom: idiom))
                            }
                        }
                        .padding(.horizontal, AppLayout.contentHMargin(idiom: idiom))
                    }
                }
            }
        }
        .skeletonShimmer()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading episodes")
    }
}

struct ServerListLoadingSkeleton: View {
    var body: some View {
        VStack(spacing: Space.s12) {
            ForEach(0..<2, id: \.self) { _ in
                HStack(spacing: Space.s14) {
                    SkeletonBlock(cornerRadius: 10)
                        .frame(width: 44, height: 44)
                    VStack(alignment: .leading, spacing: 6) {
                        SkeletonBlock(cornerRadius: 6, height: 16)
                        SkeletonBlock(cornerRadius: 4, height: 12)
                            .frame(width: 180)
                        SkeletonBlock(cornerRadius: 4, height: 10)
                            .frame(width: 120)
                    }
                }
                .padding(Space.s14)
                .background(Color.fillSecondary, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
            }
            SkeletonBlock(cornerRadius: Radius.field, height: 50)
        }
        .padding(Space.s18)
        .skeletonShimmer()
    }
}

/// Placeholder for the sign-in form's body (the brand header is rendered by `LoginView` itself, so
/// the matched mark stays put through the swap). Flattened to match the cardless auth screens — the
/// field group + a CTA block straight on the floor, no inner panel.
struct LoginCardLoadingSkeleton: View {
    var body: some View {
        VStack(spacing: Space.s22) {
            VStack(spacing: Space.s12) {
                SkeletonBlock(cornerRadius: Radius.field, height: 50)
                SkeletonBlock(cornerRadius: Radius.field, height: 50)
                SkeletonBlock(cornerRadius: Radius.field, height: 50)
            }
            SkeletonBlock(cornerRadius: Radius.field, height: 50)
        }
        .skeletonShimmer()
    }
}

struct QuickConnectLoadingSkeleton: View {
    var body: some View {
        VStack(spacing: 16) {
            SkeletonBlock(cornerRadius: 6, height: 14)
                .padding(.horizontal, Space.s8)
            SkeletonBlock(cornerRadius: 16, height: 88)
            SkeletonBlock(cornerRadius: 4, height: 12)
                .frame(width: 160)
        }
        .skeletonShimmer()
    }
}

/// Compact pill for in-flight search refinement (replaces a trailing `ProgressView`).
struct SearchRefiningSkeleton: View {
    var body: some View {
        SkeletonBlock(cornerRadius: 20, height: 12)
            .frame(width: 72)
            .skeletonShimmer()
            .padding(10)
            // Flat app-drawn chrome (matches `surfacePanel`): this pill floats over the search RESULTS
            // grid, not the player or a system bar, so Liquid Glass isn't earned here (material rule).
            .background(Color.surface, in: Capsule())
            .overlay { Capsule().strokeBorder(Color.separator, lineWidth: 1) }
            .padding(.top, Space.s8)
    }
}

// Render-verification asset for `SkeletonShimmerModifier` (GeometryReader →
// onGeometryChange): confirms the hero band + two shelves lay out and the shimmer
// overlay masks to the blocks without breaking the skeleton geometry. The sweep is
// time-driven, so a static snapshot proves layout integrity, not the animation.
#Preview("Home skeleton", traits: .fixedLayout(width: 420, height: 820)) {
    HomeLoadingSkeleton()
        .environment(\.appIdiom, .compact)
}