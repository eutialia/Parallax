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

extension View {
    /// Paints a skeleton block over this view's LAYOUT and hides the view itself — the stub then
    /// measures whatever the real thing measures (a text line box, a control's frame) instead of a
    /// hand-copied number that's only right at one Dynamic Type size on one platform.
    func skeletonStandIn<S: Shape>(in shape: S) -> some View {
        hidden()
            .overlay { shape.fill(Color.fill) }
            .accessibilityHidden(true)
    }

    func skeletonStandIn(cornerRadius: CGFloat) -> some View {
        skeletonStandIn(in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

/// A stub whose height IS the line box of `font` at the current Dynamic Type size and on the
/// current platform's type ramp — the fix for the whole family of hardcoded `height: 14` stubs that
/// only lined up with the real text at the iOS default size (render-measured: 30pt short at AX3).
/// Pass the SAME font the real line uses; `width` pins the bar's length, otherwise it fills.
///
/// The height source is a blank `Text` in that font, so it tracks `@ScaledMetric`/`.scaledFont`
/// call sites too — apply the modifier to the `SkeletonText` and leave `font` nil to inherit it.
struct SkeletonText: View {
    /// nil inherits the enclosing font (the `.scaledFont` hero-title case).
    var font: Font? = nil
    var width: CGFloat? = nil
    var cornerRadius: CGFloat = 4

    var body: some View {
        lineBox
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(width: width)
            .skeletonStandIn(cornerRadius: cornerRadius)
    }

    // `.font(nil)` would CLEAR an inherited font rather than pass it through, so the two cases
    // are separate views instead of one optional argument.
    @ViewBuilder
    private var lineBox: some View {
        if let font {
            Text(verbatim: " ").font(font)
        } else {
            Text(verbatim: " ")
        }
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

/// Placeholder identity. Skeletons feed the REAL layout containers (`MetadataRow`, `MediaGrid`)
/// rather than re-implementing them, and those are generic over `Identifiable & Hashable` items —
/// this is the nothing-item that lets a placeholder row through them.
struct SkeletonItem: Identifiable, Hashable {
    let id: Int
}

/// Tile placeholder — mirrors `MediaTile`. Poster grids show the bare artwork block (0 lines);
/// tiles with an under-thumbnail caption reserve it by line count so the loading→loaded swap
/// doesn't shift the grid: 2 = filename + duration (`MediaTile.metadataRow`, the SMB video tiles
/// and episode shelves), 1 = a lone name line (`FolderBrowseCard`).
struct MediaTileSkeleton: View {
    var aspectRatio: CGFloat = MediaImage.poster
    var metadataLines: Int = 0

    var body: some View {
        VStack(alignment: .leading, spacing: MediaTile.metadataGap) {
            SkeletonBlock(cornerRadius: Radius.tile)
                .aspectRatio(aspectRatio, contentMode: .fit)
            if metadataLines > 0 {
                // Stub lines reserving the real `MediaTile.metadataRow`'s rendered height so the
                // loading→loaded swap doesn't shift the grid. Both the spacing AND the two fonts
                // come from MediaTile's shared statics, and `SkeletonText` derives each bar's
                // height from its font's line box — so the reserve tracks Dynamic Type and the
                // tvOS ramp instead of freezing at the iOS default size.
                VStack(alignment: .leading, spacing: MediaTile.metadataLineSpacing) {
                    SkeletonText(font: MediaTile.metadataTitleFont)
                    if metadataLines > 1 {
                        SkeletonText(font: MediaTile.metadataDetailFont, width: 56)
                    }
                }
            }
        }
    }
}

/// A shelf placeholder that IS the real shelf: `MetadataRow` with placeholder items and
/// `MediaTileSkeleton` for content, redacted so the header renders as a bar.
///
/// It renders the shipping container rather than a copy of it, which is the whole point — the copy
/// this replaced had drifted on every metric the tv branch later added (header→row gap 8 vs 22,
/// header type, inter-tile gap 12 vs 40), landing the tv skeleton's second shelf 95pt off the
/// loaded one (render-measured). Redaction masks the title's glyphs while "maintaining
/// their original size and shape" (`RedactionReasons.placeholder`), so the header keeps the exact
/// line box the loaded shelf's does; the tile blocks are shapes, which redaction leaves alone.
///
/// Pass the title the shelf will actually show — Home's two shelves and a season row are all known
/// strings, so the bar even lands at the right width.
struct ShelfSkeleton: View {
    let title: String
    let tileWidth: CGFloat
    var aspectRatio: CGFloat = MediaImage.landscape
    /// Under-thumbnail caption lines to reserve — see `MediaTileSkeleton.metadataLines`.
    var metadataLines: Int = 0

    @Environment(\.appIdiom) private var idiom
    @State private var rowWidth: CGFloat = 0

    /// Enough tiles to fill the row edge-to-edge plus one peeking past the trailing edge
    /// (the cue that the real shelf scrolls). Derived from the live width — `onGeometryChange`
    /// rather than a fixed count, so it fits any screen: a fixed 7 underfills an iPad in
    /// landscape and overflows an iPhone. `.up + 1` errs toward overflow, which the disabled
    /// ScrollView clips, so the row never falls short of the edge.
    private var tiles: [SkeletonItem] {
        guard rowWidth > 0 else { return (0..<4).map(SkeletonItem.init) }
        let gap = AppLayout.shelfTileGap(idiom: idiom)
        let count = Int((rowWidth / (tileWidth + gap)).rounded(.up)) + 1
        return (0..<count).map(SkeletonItem.init)
    }

    var body: some View {
        MetadataRow(title: title, items: tiles, tileWidth: tileWidth) { _ in
            MediaTileSkeleton(aspectRatio: aspectRatio, metadataLines: metadataLines)
        }
        .redacted(reason: .placeholder)
        .scrollDisabled(true)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { rowWidth = $0 }
    }
}

// MARK: - Screen layouts

struct HomeLoadingSkeleton: View {
    @Environment(\.appIdiom) private var idiom

    var body: some View {
        LazyVStack(alignment: .leading, spacing: Space.s30) {
            // Hero placeholder bleeds full-width like the real carousel; shelves stay title-safe.
            // `heroBandFrame` rather than a bare aspect ratio: it's the same modifier the loaded
            // carousel uses, so tvOS takes the viewport-MEASURED height path there instead of a
            // width-derived band the real hero never draws.
            SkeletonBlock(cornerRadius: 0)
                .heroBandFrame(regularWidth: idiom.usesLandscapeHeroBand)
            VStack(alignment: .leading, spacing: Space.s30) {
                // The shelves Home always opens with, at the idiom's real tile width (tv is 220,
                // not iPhone's 172 — the hardcoded `HomeShelf.tileWidth` here made every tv
                // skeleton row 72pt short).
                shelf("Continue Watching")
                shelf("Next Up")
            }
            .tvContentInset()
        }
        .padding(.bottom, Space.s30)
        .skeletonShimmer()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading")
    }

    private func shelf(_ title: String) -> some View {
        ShelfSkeleton(
            title: title,
            tileWidth: AppLayout.shelfTileWidth(idiom: idiom),
            aspectRatio: MediaImage.poster
        )
    }
}

/// The search screen's first-load grid skeleton. Draws the SECTION ONLY — its enclosing ScrollView
/// (`JellyfinSearchView.content` on iOS/iPadOS, `TVSearchScopeSurface` on tvOS) owns the insets via
/// `contentMargins`, exactly as the loaded `JellyfinSearchResultsView` does, so the two surfaces
/// can't inset differently and the swap stays shift-free. (It used to apply its own `.padding`,
/// which had to be kept in sync by hand with the loaded grid's.)
///
/// The section HEADER is the load-bearing part: results always arrive inside a `GridSection`
/// (Shows / Movies / Episodes), and a bare grid here dropped the first tile row 37pt higher than
/// the results that replaced it — the single biggest jump the parity audit found. One section is enough:
/// the header is the offset, the section count isn't.
struct PosterGridLoadingSkeleton: View {
    let columns: Int
    let rows: Int

    @Environment(\.appIdiom) private var idiom

    var body: some View {
        // The real section container, redacted — same header type, same `focusSafeHeaderGap`, no
        // second copy of either to drift. `count: nil` because a placeholder has no number to
        // report (the count rides a smaller type tier and doesn't set the header's height).
        GridSection(title: "Results", count: nil) {
            // Same idiom-aware gaps as the loaded search grid (JellyfinSearchResultsView) —
            // hardcoded 12/18 here would visibly re-space the whole grid on the skeleton→results
            // swap now that the loaded side uses the 40pt tvOS focus-clearance tokens.
            LazyVGrid(
                columns: posterGridColumns(
                    fixedColumns: columns,
                    columnSpacing: AppLayout.posterGridColumnSpacing(idiom: idiom)
                ),
                spacing: AppLayout.posterGridRowSpacing(idiom: idiom)
            ) {
                ForEach(0..<(columns * rows), id: \.self) { _ in
                    MediaTileSkeleton()
                }
            }
        }
        .redacted(reason: .placeholder)
        .skeletonShimmer()
        // The redacted header still carries `GridSection`'s header trait, so fold the whole
        // placeholder into one element rather than letting VoiceOver announce a stand-in title.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading results")
    }
}

/// The poster-grid placeholder WITHOUT a shimmer clock, for screens that wrap it in more
/// placeholder chrome (a redacted section header, the tvOS chip row). Those hosts apply
/// `.skeletonShimmer()` once at their own top so the whole screen sweeps under a single clock —
/// embedding the shimmering variant instead leaves the header as the one static bar on the screen.
struct AdaptivePosterGridPlaceholderGrid: View {
    let tileCount: Int
    /// Fixed column count. Mirrors `MediaGrid`.
    var fixedColumns: Int
    /// Tile shape — `.poster` for Jellyfin grids, `.landscape` for SMB frame-grab grids, so the
    /// skeleton matches the loaded tiles and the swap stays shift-free.
    var aspectRatio: CGFloat = MediaImage.poster
    /// Under-thumbnail caption lines to reserve (SMB grids) so the swap to loaded tiles is
    /// shift-free — see `MediaTileSkeleton.metadataLines`.
    var metadataLines: Int = 0

    @Environment(\.appIdiom) private var idiom

    var body: some View {
        let columns = posterGridColumns(
            fixedColumns: fixedColumns,
            columnSpacing: AppLayout.posterGridColumnSpacing(idiom: idiom)
        )
        LazyVGrid(columns: columns, spacing: AppLayout.posterGridRowSpacing(idiom: idiom)) {
            ForEach(0..<tileCount, id: \.self) { _ in
                MediaTileSkeleton(aspectRatio: aspectRatio, metadataLines: metadataLines)
            }
        }
    }
}

/// The grid placeholder as a self-contained skeleton region: the grid plus its own shimmer clock.
/// Use it where the grid IS the whole placeholder (a bare first-load wall, a load-more strip under
/// loaded content); inside a bigger placeholder use `AdaptivePosterGridPlaceholderGrid`.
struct AdaptivePosterGridLoadingSkeleton: View {
    let tileCount: Int
    var fixedColumns: Int
    var aspectRatio: CGFloat = MediaImage.poster
    var metadataLines: Int = 0

    var body: some View {
        AdaptivePosterGridPlaceholderGrid(
            tileCount: tileCount,
            fixedColumns: fixedColumns,
            aspectRatio: aspectRatio,
            metadataLines: metadataLines
        )
        .skeletonShimmer()
    }
}

/// First-list placeholder for one SMB browse level — the shape of `SMBBrowseGrid` (tvOS sort chip,
/// a "Folders" row, then a "Videos" wall at the dense landscape column count) instead of the bare
/// centered spinner every level used to show. The exact loaded geometry depends on the listing
/// (folder/video counts), so this is an impression of the wall, not a shift-free contract like the
/// poster-grid skeletons; section stubs + tiles use the same tokens as the real grid so nothing
/// re-spaces on arrival. Built from raw grids (not `AdaptivePosterGridLoadingSkeleton`) so ONE
/// `skeletonShimmer()` clock drives the whole screen.
struct SMBBrowseLoadingSkeleton: View {
    @Environment(\.appIdiom) private var idiom

    var body: some View {
        let columnCount = AppLayout.landscapeGridColumns(idiom: idiom)
        let columns = posterGridColumns(
            fixedColumns: columnCount,
            columnSpacing: AppLayout.posterGridColumnSpacing(idiom: idiom)
        )
        // Chip in a spacing-0 wrapper mirroring the loaded tree (`VStack(spacing: 0) { sortHeader;
        // SMBBrowseGrid }`): its own bottom clearance is the ONLY gap under it — parking it inside
        // the section-spaced stack double-gapped the first section 52pt low.
        VStack(alignment: .leading, spacing: 0) {
            if idiom == .tv {
                // The lone Sort chip's stand-in, centered like `SMBBrowseView.sortHeader` — same
                // metrics family as the library header's chip skeleton, same row tokens as the
                // real chip.
                Capsule().fill(Color.fill)
                    .frame(width: LibraryHeaderChip.sortWidth, height: LibraryHeaderChip.height)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, AppLayout.chipRowTopPadding)
                    .padding(.bottom, AppLayout.chipRowBottomClearance)
            }
            VStack(alignment: .leading, spacing: AppLayout.browseSectionGap(idiom: idiom)) {
                // Folders carry a single name line under the card; videos the filename + duration
                // pair — mirror both so neither section's rows land short/tall before the swap.
                browseSectionSkeleton(rows: 1, metadataLines: 1, columnCount: columnCount, columns: columns)
                browseSectionSkeleton(rows: 2, metadataLines: 2, columnCount: columnCount, columns: columns)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .skeletonShimmer()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading contents")
        // A content-less tvOS screen needs a focus target or a Menu press suspends the app —
        // carried IN the skeleton (like `DetailLoadingSkeleton`) so no future host can forget it.
        .tvFocusableSurface()
    }

    /// One titled group stub (mirrors `SMBBrowseGrid.browseSection`): a `.sectionHeader`-sized
    /// line above a landscape tile grid with the under-thumbnail caption reserved.
    private func browseSectionSkeleton(rows: Int, metadataLines: Int, columnCount: Int, columns: [GridItem]) -> some View {
        VStack(alignment: .leading, spacing: Space.s8) {
            // Height IS `.sectionHeader`'s line box (23pt semibold on tvOS, footnote-class on
            // iOS) — the fixed 28/13 pair it replaces was a hand measurement of exactly that,
            // and only correct at the default Dynamic Type size.
            SkeletonText(font: .sectionHeader, width: 88)
            LazyVGrid(columns: columns, spacing: AppLayout.posterGridRowSpacing(idiom: idiom)) {
                ForEach(0..<(columnCount * rows), id: \.self) { _ in
                    MediaTileSkeleton(aspectRatio: MediaImage.landscape, metadataLines: metadataLines)
                }
            }
        }
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

/// The movie/series detail placeholder, built on the SAME containers the loaded page uses —
/// `HeroBand` + `heroBandFrame` for the band, `HeroForeground` for the bottom-anchored title/action
/// column, `HeroMetrics.floorTextClearance` for the band→ledger gap. The band and the ledger below
/// it are shift-free by construction (same frame modifier, same clearance token). INSIDE the
/// bottom-anchored column the stubs only approximate the real heights — one title line vs
/// `HeroTitle`'s two-line limit or a logo box, one subtitle bar vs the badge strip — which is
/// harmless because the column grows UPWARD from the band floor: the action row and everything
/// below it stay put while a taller real title takes the extra height. Don't over-reserve here;
/// reserving two title lines would push the action row down on every one-line title.
///
/// It used to re-implement all three by hand and had drifted off every one: an `Space.s18` gap
/// where the page uses 30/34/48, 44pt action stubs where `ActionRow.controlHeight` is 50/52/76, and
/// a magic `.padding(.top, -Space.s60)` standing in for the foreground's real bottom-anchored
/// placement. The band's own artwork rides `.background` because on iPhone/iPad the shipping band
/// is a transparent spacer whose picture is mounted OUTSIDE the scroll (`HeroBackdrop`) — the
/// skeleton has no picture to mount, so it fills the reserved rect instead.
struct DetailLoadingSkeleton: View {
    /// The width reserve of the page this stands in for — movie detail's pill reserves "Resume",
    /// series detail's "Resume S99 E99". Taken from the host rather than hardcoded so the stub
    /// and the pill that replaces it are the same width on BOTH pages (one shared reserve made
    /// the movie skeleton two characters wide of its own loaded pill).
    let reserve: ItemPlayButtonLabel.ReserveKind

    @Environment(\.appIdiom) private var idiom

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: HeroMetrics.floorTextClearance(idiom: idiom)) {
                HeroBand {
                    // tvOS only — the band paints its own picture there.
                    SkeletonBlock(cornerRadius: 0)
                } foreground: {
                    HeroForeground(eyebrow: nil, title: titleStub) {
                        // The metadata badge strip's tier (`DetailHeroMetadataRow` is `.subheadline`).
                        SkeletonText(font: .subheadline, width: 200)
                    } actions: {
                        actionStubs
                    }
                }
                .heroBandFrame(regularWidth: idiom.usesLandscapeHeroBand)
                .background { SkeletonBlock(cornerRadius: 0) }

                VStack(alignment: .leading, spacing: Space.s8) {
                    ForEach(0..<4, id: \.self) { i in
                        // The ledger opens with the overview paragraph — reserve ITS line box
                        // (`.detailProse`), not a fixed 14.
                        SkeletonText(font: .detailProse)
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
        // This skeleton fills a PUSHED tvOS detail screen (which drops the tab sidebar) with no
        // interactive content — keep a focus target so a Menu press during a slow load pops the
        // stack instead of suspending the app (see `tvFocusableSurface()`).
        .tvFocusableSurface()
    }

    /// The hero title's own line box: `HeroTitle` sizes its text with `scaledFont` at the idiom's
    /// detail point size, so the stub inherits that font rather than naming a height.
    private var titleStub: some View {
        SkeletonText()
            .scaledFont(
                HeroTitle.Scale.detail.pointSize(idiom: idiom),
                relativeTo: .largeTitle,
                weight: .heavy
            )
            .padding(.trailing, Space.s40)
    }

    /// Play pill + two circle actions at the row's real control metrics — the pill takes its
    /// footprint from a hidden copy of `PrimaryPlayButton`'s label composition (`.headline` inside
    /// `Space.s22` insets at `ActionRow.controlHeight`), the discs from that same diameter.
    ///
    /// The pill's copy is the host's `layoutReserveTitle`, not "Play": both detail pages pass
    /// their reserve to `PrimaryPlayButton`, which ZStacks it behind the live title — so the
    /// shipping pill is ALWAYS the reserve's width, and a "Play"-wide stub slid the two discs right
    /// on load.
    @ViewBuilder
    private var actionStubs: some View {
        let diameter = ActionRow.controlHeight(idiom)
        Label(ItemPlayButtonLabel.layoutReserveTitle(for: reserve), systemImage: "play.fill")
            .font(.headline)
            .padding(.horizontal, Space.s22)
            .frame(height: diameter)
            .skeletonStandIn(in: Capsule())
        Circle().fill(Color.fill).frame(width: diameter, height: diameter)
        Circle().fill(Color.fill).frame(width: diameter, height: diameter)
    }
}

/// The season shelves' placeholder — the real `MetadataRow` per season (see `ShelfSkeleton`), at
/// the idiom's episode tile width, with the tile's title + time row reserved below the still.
struct EpisodeListLoadingSkeleton: View {
    @Environment(\.appIdiom) private var idiom

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s22) {
            ForEach(1...2, id: \.self) { season in
                // `metadataLines: 2`: the season-row tiles carry a title + time row BELOW the
                // still (the one-text-region law moved the caption there), so the skeleton must
                // reserve those lines or the load→loaded swap jumps.
                ShelfSkeleton(
                    title: "Season \(season)",
                    tileWidth: AppLayout.seriesEpisodeTileWidth(idiom: idiom),
                    aspectRatio: MediaImage.landscape,
                    metadataLines: 2
                )
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

#if DEBUG
import ParallaxJellyfin
import ParallaxCore

// Render-verification asset for `SkeletonShimmerModifier` (GeometryReader →
// onGeometryChange): confirms the hero band + two shelves lay out and the shimmer
// overlay masks to the blocks without breaking the skeleton geometry. The sweep is
// time-driven, so a static snapshot proves layout integrity, not the animation.
#Preview("Home skeleton", traits: .fixedLayout(width: 420, height: 820)) {
    HomeLoadingSkeleton()
        .environment(\.appIdiom, .compact)
}

// MARK: - Skeleton ↔ loaded parity harness
//
// The parity guard. Every preview below puts the PLACEHOLDER in the left column and the
// REAL screen in the right, at the same width and with the same idiom injected into BOTH halves —
// a missing injection silently renders compact gaps on one side and the render certifies nothing
// (see JellyfinSearchResultsView's idiom note). Judge them with
//
//     python3 scripts/render-ruler.py --pt-width <canvas> --scan-col 0.25,0.75
//
// which prints the vertical run-lengths down one column inside each half: PASS = the first header
// / first tile run starts on the same row (±1pt) in both. Numbers from the script; read the image
// only for the qualitative "does it read as the same screen" call.

/// Side-by-side host for the parity previews — see the note above.
private struct SkeletonParity<Skeleton: View, Loaded: View>: View {
    let idiom: AppIdiom
    let columnWidth: CGFloat
    @ViewBuilder var skeleton: () -> Skeleton
    @ViewBuilder var loaded: () -> Loaded

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            column { skeleton() }
            column { loaded() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // Pure black, not `Color.background`: the floor token's dark face lands one luminance
        // step above `render-ruler.py`'s background threshold, so every gap read as content and
        // the run-lengths merged. On black the gaps drop out and each header/tile edge is its
        // own run. Judge color elsewhere; this canvas exists to be measured.
        .background(.black)
        .preferredColorScheme(.dark)
    }

    private func column<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .frame(width: columnWidth)
            .frame(maxHeight: .infinity, alignment: .top)
            .environment(\.appIdiom, idiom)
            .clipped()
    }
}

/// Poster fixtures for the loaded halves — placeholder artwork (the `.invalid` preview session
/// fails fast), which is exactly what a shelf/grid shows before its images resolve.
private func parityMovies(_ count: Int) -> [SourcedItem] {
    (1...count).map { i in
        SourcedItem(
            item: .movie(Movie(
                id: ItemID(rawValue: "m\(i)"), title: "Movie \(i)", overview: nil, year: 2019,
                runtime: .seconds(6000), communityRating: nil, officialRating: nil, genres: [],
                primaryTag: nil, backdropTags: [], logoTag: nil, thumbTag: nil,
                userData: UserItemData(played: false, playbackPositionTicks: 0, playCount: 0, isFavorite: false)
            )),
            source: .jellyfin(.preview)
        )
    }
}

/// The loaded Home feed's shape: the hero band, then the two poster shelves at the idiom's
/// shelf tile width — the exact containers `HomeLoadingSkeleton` has to stand in for.
private struct LoadedHomeFeed: View {
    @Environment(\.appIdiom) private var idiom

    var body: some View {
        let tiles = (0..<8).map(SkeletonItem.init)
        VStack(alignment: .leading, spacing: Space.s30) {
            Color.artworkPlaceholder
                .heroBandFrame(regularWidth: idiom.usesLandscapeHeroBand)
            VStack(alignment: .leading, spacing: Space.s30) {
                shelf("Continue Watching", tiles: tiles)
                shelf("Next Up", tiles: tiles)
            }
            .tvContentInset()
        }
        .padding(.bottom, Space.s30)
    }

    private func shelf(_ title: String, tiles: [SkeletonItem]) -> some View {
        MetadataRow(title: title, items: tiles, tileWidth: AppLayout.shelfTileWidth(idiom: idiom)) { _ in
            MediaTile(title: "Title", imageRef: nil, session: .preview, aspectRatio: MediaImage.poster)
        }
    }
}

/// The plain scroll shell the real screens put both states in (`HomeView`, `SeriesDetailView`),
/// and it matters here: outside a scroll the fixed canvas under-proposes, which silently
/// compresses the aspect-ratio hero band and stretches a shelf's inner scroll — measuring a
/// layout the app never draws.
private struct ScrollShell<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        ScrollView { content() }.scrollDisabled(true)
    }
}

#Preview("Home skeleton ↔ loaded (compact)", traits: .fixedLayout(width: 786, height: 1320)) {
    SkeletonParity(idiom: .compact, columnWidth: 393) {
        ScrollShell { HomeLoadingSkeleton() }
    } loaded: {
        ScrollShell { LoadedHomeFeed() }
    }
}

#Preview("Home skeleton ↔ loaded (tv)", traits: .fixedLayout(width: 1920, height: 1440)) {
    SkeletonParity(idiom: .tv, columnWidth: 960) {
        ScrollShell { HomeLoadingSkeleton() }
    } loaded: {
        ScrollShell { LoadedHomeFeed() }
    }
}

/// Both halves in the SEARCH screen's own scroll shell — `JellyfinSearchView` owns the margins for
/// the skeleton and the results alike, so the parity check has to include them.
private struct SearchShell<Content: View>: View {
    @Environment(\.appIdiom) private var idiom
    @ViewBuilder var content: () -> Content

    var body: some View {
        ScrollView { content() }
            .scrollDisabled(true)
            .contentMargins(.horizontal, AppLayout.contentHMargin(idiom: idiom), for: .scrollContent)
            .contentMargins(.vertical, AppLayout.searchContentVMargin(idiom: idiom), for: .scrollContent)
    }
}

#Preview("Search skeleton ↔ results", traits: .fixedLayout(width: 786, height: 700)) {
    NavigationStack {
        SkeletonParity(idiom: .compact, columnWidth: 393) {
            SearchShell { PosterGridLoadingSkeleton(columns: 3, rows: 2) }
        } loaded: {
            SearchShell {
                JellyfinSearchResultsView(results: AggregatedSearchResults(movies: parityMovies(6)))
            }
        }
    }
    .environment(PlaybackPresenter())
}

/// The detail page's loaded shape, staged like `HeroBand`'s "floor clearance" previews: band,
/// bottom-anchored hero foreground, then the ledger's first text a `floorTextClearance` below.
private struct LoadedDetailPage: View {
    @Environment(\.appIdiom) private var idiom

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: HeroMetrics.floorTextClearance(idiom: idiom)) {
                HeroBand {
                    Color.artworkPlaceholder
                } foreground: {
                    HeroForeground(
                        eyebrow: nil,
                        title: HeroTitle(
                            title: "Orbital", logoRef: nil, session: .preview,
                            idiom: idiom, usesLogo: false, scale: .detail
                        )
                    ) {
                        Text("2024 · 1h 52m · PG-13")
                            .font(.subheadline)
                            .foregroundStyle(.white)
                    } actions: {
                        // The reserve is what makes this a parity check: both shipping detail
                        // pages pass one, so the loaded pill is reserve-wide no matter what the
                        // live title says. Dropping it here let a "Play"-wide skeleton stub pass
                        // a render it should have failed. This fixture is a MOVIE, so it takes
                        // the movie reserve — the same one the skeleton half is given.
                        PrimaryPlayButton(
                            title: "Play",
                            fillWidth: false,
                            layoutReserveTitle: ItemPlayButtonLabel.layoutReserveTitle(for: .verbOnly)
                        ) { }
                        CircleGlassButton(systemImage: "heart", accessibilityLabel: "Favorite") { }
                        CircleGlassButton(systemImage: "checkmark", accessibilityLabel: "Mark Watched") { }
                    }
                }
                .heroBandFrame(regularWidth: idiom.usesLandscapeHeroBand)
                .background { Color.artworkPlaceholder }

                Text("A crew on humanity's last orbital station races to prevent a cascade failure before re-entry, rationing oxygen while the ground crew fights to reach them in time.")
                    .font(.detailProse)
                    .foregroundStyle(Color.label)
                    .padding(.horizontal, AppLayout.contentHMargin(idiom: idiom))
                    .tvContentInset()
            }
            .padding(.bottom, Space.s30)
        }
        .scrollDisabled(true)
    }
}

#Preview("Detail skeleton ↔ hero (compact)", traits: .fixedLayout(width: 786, height: 1000)) {
    SkeletonParity(idiom: .compact, columnWidth: 393) {
        DetailLoadingSkeleton(reserve: .verbOnly)
    } loaded: {
        LoadedDetailPage()
    }
}

#Preview("Detail skeleton ↔ hero (regular)", traits: .fixedLayout(width: 2048, height: 1000)) {
    SkeletonParity(idiom: .regular, columnWidth: 1024) {
        DetailLoadingSkeleton(reserve: .verbOnly)
    } loaded: {
        LoadedDetailPage()
    }
}

/// The season shelves — the ONLY skeleton that combines the redacted header with `SkeletonText`
/// caption stubs, so it's where a double-draw would show (a redaction placeholder painted UNDER
/// the stub's own bar). Each tile must show exactly two caption bars, and the tile tops must match
/// the loaded shelf's.
#Preview("Episode shelves skeleton ↔ loaded", traits: .fixedLayout(width: 1180, height: 900)) {
    let episodes = (0..<4).map(SkeletonItem.init)
    return SkeletonParity(idiom: .compact, columnWidth: 590) {
        ScrollShell { EpisodeListLoadingSkeleton() }
    } loaded: {
        ScrollShell {
        VStack(alignment: .leading, spacing: Space.s22) {
            ForEach(1...2, id: \.self) { season in
                MetadataRow(
                    title: "Season \(season)",
                    items: episodes,
                    tileWidth: AppLayout.seriesEpisodeTileWidth(idiom: .compact)
                ) { _ in
                    MediaTile(
                        title: "E3 · The One With the Embryos",
                        artwork: .none,
                        aspectRatio: MediaImage.landscape,
                        metadata: .init(leading: "22 min left", trailing: nil)
                    )
                }
            }
        }
        }
    }
}
#endif