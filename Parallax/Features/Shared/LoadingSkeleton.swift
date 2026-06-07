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

    func body(content: Content) -> some View {
        if reduceMotion {
            content
        } else {
            content.overlay {
                GeometryReader { geo in
                    TimelineView(.animation) { context in
                        let period: TimeInterval = 1.35
                        let phase = context.date.timeIntervalSinceReferenceDate
                            .truncatingRemainder(dividingBy: period) / period
                        let band = geo.size.width * 0.35
                        LinearGradient(
                            colors: [.clear, Color.white.opacity(0.28), .clear],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                        .frame(width: band)
                        .offset(x: (geo.size.width + band) * phase - band)
                    }
                }
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

/// Poster-only placeholder — mirrors `MediaTile`, which dropped its title/subtitle text.
struct MediaTileSkeleton: View {
    var aspectRatio: CGFloat = JellyfinImage.poster

    var body: some View {
        SkeletonBlock(cornerRadius: Radius.tile)
            .aspectRatio(aspectRatio, contentMode: .fit)
    }
}

struct MetadataRowSkeleton: View {
    let tileWidth: CGFloat
    var aspectRatio: CGFloat = JellyfinImage.landscape

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
                .padding(.horizontal, AppLayout.contentHMargin)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: Space.s12) {
                    ForEach(0..<tileCount, id: \.self) { _ in
                        MediaTileSkeleton(aspectRatio: aspectRatio)
                            .frame(width: tileWidth)
                    }
                }
                .padding(.horizontal, AppLayout.contentHMargin)
            }
            .scrollDisabled(true)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { rowWidth = $0 }
    }
}

// MARK: - Screen layouts

struct HomeLoadingSkeleton: View {
    @Environment(\.horizontalSizeClass) private var hSize

    var body: some View {
        LazyVStack(alignment: .leading, spacing: Space.s30) {
            SkeletonBlock(cornerRadius: 0)
                .aspectRatio(
                    HeroMetrics.bandAspectRatio(regularWidth: hSize == .regular),
                    contentMode: .fit
                )
            MetadataRowSkeleton(tileWidth: HomeShelf.tileWidth, aspectRatio: JellyfinImage.poster)
            MetadataRowSkeleton(tileWidth: HomeShelf.tileWidth, aspectRatio: JellyfinImage.poster)
        }
        .padding(.bottom, Space.s30)
        .skeletonShimmer()
    }
}

struct PosterGridLoadingSkeleton: View {
    let columns: Int
    let rows: Int

    var body: some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: Space.s12), count: columns),
            spacing: Space.s18
        ) {
            ForEach(0..<(columns * rows), id: \.self) { _ in
                MediaTileSkeleton()
            }
        }
        .padding(Space.s18)
        .skeletonShimmer()
    }
}

struct AdaptivePosterGridLoadingSkeleton: View {
    let tileCount: Int
    var columnMinWidth: CGFloat = 140
    /// Fixed column count; when nil the grid adapts by `columnMinWidth`. Mirrors `MediaGrid`.
    var fixedColumns: Int? = nil

    var body: some View {
        let columns = posterGridColumns(fixedColumns: fixedColumns, columnMinWidth: columnMinWidth)
        LazyVGrid(columns: columns, spacing: 16) {
            ForEach(0..<tileCount, id: \.self) { _ in
                MediaTileSkeleton()
            }
        }
        .skeletonShimmer()
    }
}

struct LibraryListLoadingSkeleton: View {
    let columns: Int

    var body: some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: Space.s12), count: columns),
            spacing: Space.s12
        ) {
            ForEach(0..<(columns * 3), id: \.self) { _ in
                SkeletonBlock(cornerRadius: Radius.card)
                    .aspectRatio(JellyfinImage.landscape, contentMode: .fit)
            }
        }
        .padding(Space.s18)
        .skeletonShimmer()
    }
}

/// Full-height library-list placeholder: column count tracks the size class and the
/// disabled `ScrollView` lets it fill the screen like the loaded grid. Shared by the
/// Library list, its bootstrap host, and the per-server task gate.
struct LibraryListLoadingPlaceholder: View {
    @Environment(\.horizontalSizeClass) private var hSize

    var body: some View {
        ScrollView {
            LibraryListLoadingSkeleton(columns: hSize == .regular ? 2 : 1)
        }
        .scrollDisabled(true)
    }
}

struct DetailLoadingSkeleton: View {
    @Environment(\.horizontalSizeClass) private var hSize

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.s18) {
                SkeletonBlock(cornerRadius: 0)
                    .aspectRatio(
                        HeroMetrics.bandAspectRatio(regularWidth: hSize == .regular),
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
                .padding(.horizontal, Space.s18)
                .padding(.top, -Space.s60)

                VStack(alignment: .leading, spacing: Space.s8) {
                    ForEach(0..<4, id: \.self) { i in
                        SkeletonBlock(cornerRadius: 6, height: 14)
                            .padding(.trailing, CGFloat(40 + i * 18))
                    }
                }
                .padding(.horizontal, Space.s18)
            }
            .padding(.bottom, Space.s30)
            .skeletonShimmer()
        }
        .scrollDisabled(true)
    }
}

struct EpisodeListLoadingSkeleton: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Space.s22) {
            ForEach(0..<2, id: \.self) { _ in
                VStack(alignment: .leading, spacing: Space.s8) {
                    SkeletonBlock(cornerRadius: 6, height: 22)
                        .frame(width: 120)
                        .padding(.horizontal, AppLayout.contentHMargin)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: Space.s12) {
                            ForEach(0..<5, id: \.self) { _ in
                                SkeletonBlock(cornerRadius: Radius.tile)
                                    .frame(
                                        width: SeriesShelf.episodeTileWidth,
                                        height: SeriesShelf.episodeTileWidth / JellyfinImage.landscape
                                    )
                            }
                        }
                        .padding(.horizontal, AppLayout.contentHMargin)
                    }
                }
            }
        }
        .skeletonShimmer()
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

struct LoginCardLoadingSkeleton: View {
    var body: some View {
        VStack(spacing: Space.s22) {
            SkeletonBlock(cornerRadius: Radius.card, height: 72)
            VStack(spacing: Space.s12) {
                SkeletonBlock(cornerRadius: Radius.field, height: 50)
                SkeletonBlock(cornerRadius: Radius.field, height: 50)
                SkeletonBlock(cornerRadius: Radius.field, height: 50)
            }
            SkeletonBlock(cornerRadius: Radius.field, height: 50)
        }
        .skeletonShimmer()
        .padding(Space.s22)
        .background(Color.fillSecondary, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
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
            .background(.regularMaterial, in: Capsule())
            .padding(.top, Space.s8)
    }
}