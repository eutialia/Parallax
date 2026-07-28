import SwiftUI
import ParallaxJellyfin
import ParallaxCore

/// The search results sections — Shows / Movies / Episodes — split out as an `Equatable` view so
/// typing can't re-render them.
///
/// The search field's text lives in the parent's `@State`, so every keystroke re-evaluates
/// the parent body — which previously rebuilt every `MediaTile` and made typing lag.
/// Wrapping the sections in `.equatable()` lets SwiftUI skip them whenever `results` is
/// unchanged — i.e. on every keystroke that doesn't change the results.
///
/// CONTENT ONLY: the enclosing scroll view, its `contentMargins`, and (on tvOS) the scope-chip row
/// above it all belong to the screen (`JellyfinSearchView` / `TVSearchScopeSurface`), not here.
/// They have to outlive this view — the chip row must keep its focus while the state under it swaps
/// between a grid, a skeleton, and an empty state — and a scroll owned by the loaded branch could
/// never do that.
///
/// The idiom comes from `@Environment(\.appIdiom)`, NOT a stored property. `GridSection` — this
/// view's own child — already reads it from the environment, so threading a second copy down as a
/// parameter gave the screen two sources that could disagree, and they DID: the previews rendered
/// tv-idiom columns at compact gaps until the environment injection was added. One source now.
/// That's safe under the `==` gate because an environment read is a graph dependency tracked
/// independently of the view-value comparison (the same reason `@State` still updates an
/// `.equatable()` view) — the memoization only skips re-renders caused by the PARENT's keystrokes.
/// Keep other per-render state out of here all the same; dispatch goes through `ItemNavigator`,
/// which owns its own playback/navigation environment.
struct JellyfinSearchResultsView: View, Equatable {
    /// Source-tagged: results mix servers, so each tile resolves ITS OWN session for artwork and
    /// playback rather than sharing one screen-level session.
    let results: AggregatedSearchResults

    static func == (lhs: JellyfinSearchResultsView, rhs: JellyfinSearchResultsView) -> Bool {
        lhs.results == rhs.results
    }

    @Environment(\.appIdiom) private var idiom

    private var posterCols: Int { AppLayout.searchPosterColumns(idiom: idiom) }
    private var landscapeCols: Int { AppLayout.searchLandscapeColumns(idiom: idiom) }

    var body: some View {
        // Focus-safe inter-section gap: a section's last row carries the same lift as any other, so
        // it needs the same clearance before the next section's header (40pt on tvOS, the tight
        // 26pt on iPhone/iPad, which have no lift).
        VStack(alignment: .leading, spacing: AppLayout.focusSafeSectionGap(idiom: idiom)) {
            if !results.series.isEmpty {
                gridSection("Shows", count: results.series.count, cols: posterCols) {
                    ForEach(results.series) { sourced in
                        if let session = sourced.jellyfinSession, case .series(let s) = sourced.item {
                            ItemNavigator(item: sourced.item, session: session) {
                                MediaTile(title: s.title, imageRef: s.imageRef(.primary), session: session, watched: .init(sourced.item), aspectRatio: MediaImage.poster, maxImageWidth: 400)
                            }
                        }
                    }
                }
            }
            if !results.movies.isEmpty {
                gridSection("Movies", count: results.movies.count, cols: posterCols) {
                    ForEach(results.movies) { sourced in
                        if let session = sourced.jellyfinSession, case .movie(let m) = sourced.item {
                            ItemNavigator(item: sourced.item, session: session) {
                                MediaTile(title: m.title, imageRef: m.imageRef(.primary), session: session, watched: .init(sourced.item), aspectRatio: MediaImage.poster, maxImageWidth: 400)
                            }
                        }
                    }
                }
            }
            if !results.episodes.isEmpty {
                gridSection("Episodes", count: results.episodes.count, cols: landscapeCols) {
                    ForEach(results.episodes) { sourced in
                        if let session = sourced.jellyfinSession, case .episode(let e) = sourced.item {
                            ItemNavigator(item: sourced.item, session: session) {
                                // Episodes need the detail row a poster doesn't: neither the still
                                // nor the episode name says which show this is. `.lockup()` so the
                                // tvOS focus lift nudges that row aside instead of landing on it.
                                MediaTile(
                                    title: e.name, imageRef: e.stillFirstImageRef, session: session,
                                    watched: .init(sourced.item), aspectRatio: MediaImage.landscape, maxImageWidth: 500,
                                    metadata: .init(leading: e.seriesContextCaption, trailing: e.timeCaption())
                                )
                                .lockup()
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func gridSection<Content: View>(_ title: String, count: Int, cols: Int, @ViewBuilder content: () -> Content) -> some View {
        GridSection(title: title, count: count, countNoun: "result") {
            // Shared idiom-aware gaps (40pt on tvOS) so a focused tile's lift
            // clears its neighbours — the same fix `libraryListSpacing` records.
            LazyVGrid(
                columns: posterGridColumns(
                    fixedColumns: cols, columnMinWidth: 0,
                    columnSpacing: AppLayout.posterGridColumnSpacing(idiom: idiom)
                ),
                spacing: AppLayout.posterGridRowSpacing(idiom: idiom)
            ) {
                content()
            }
        }
    }
}

#if DEBUG
private func previewEpisode(
    _ id: String, name: String, series: String? = nil, season: Int?, index: Int?, runtimeMinutes: Int?,
    played: Bool = false, positionMinutes: Int = 0
) -> Episode {
    Episode(
        id: ItemID(rawValue: id), seriesID: ItemID(rawValue: "series"),
        seasonID: ItemID(rawValue: "season"), name: name,
        seriesName: series,
        indexNumber: index, parentIndexNumber: season,
        overview: nil, runtime: runtimeMinutes.map { .seconds($0 * 60) },
        primaryTag: nil,
        userData: UserItemData(
            played: played,
            playbackPositionTicks: Int64(positionMinutes) * 60 * 10_000_000,
            playCount: played ? 1 : 0, isFavorite: false
        )
    )
}

/// One fixture set for both previews below, so an edit can't silently desync them:
/// mid-watch ("22 min left" + progress ring), unwatched with runtime, watched (check badge),
/// a long series name squeezing against the time caption, season unknown (degrades to "E7"),
/// and indexes/runtime/series all missing (title-only row, no stray gap).
private let previewSearchEpisodes = [
    previewEpisode("e1", name: "The Winds of Winter", series: "Game of Thrones", season: 6, index: 10, runtimeMinutes: 68, positionMinutes: 46),
    previewEpisode("e2", name: "Ozymandias", series: "Breaking Bad", season: 5, index: 14, runtimeMinutes: 47),
    previewEpisode("e3", name: "Pine Barrens", series: "The Sopranos", season: 3, index: 11, runtimeMinutes: 45, played: true),
    previewEpisode("e4", name: "Special", series: "It's Always Sunny in Philadelphia", season: nil, index: 7, runtimeMinutes: 23),
    previewEpisode("e5", name: "A Very Long Episode Title That Should Truncate Cleanly", season: nil, index: nil, runtimeMinutes: nil),
]

/// The episode detail row across its data shapes (see `previewSearchEpisodes`). The placeholder
/// artwork stands in for stills — the row under the thumbnail is what's under test.
#Preview("Episode metadata rows") {
    let results = AggregatedSearchResults(
        episodes: previewSearchEpisodes.map { SourcedItem(item: .episode($0), source: .jellyfin(.preview)) }
    )
    NavigationStack {
        // The sections are content-only now, so the preview supplies the scroll shell the screen
        // supplies in production (`JellyfinSearchView`'s iOS branch) — same margins, same knob.
        ScrollView {
            JellyfinSearchResultsView(results: results)
        }
        .contentMargins(.horizontal, AppLayout.contentHMargin(idiom: .compact), for: .scrollContent)
        .contentMargins(.vertical, AppLayout.searchContentVMargin(idiom: .compact), for: .scrollContent)
    }
    .environment(PlaybackPresenter())
    .background(Color.background)
    // The view reads its idiom from the environment (see the type's doc comment); `.compact` is
    // the environment default, but pin it so this preview can't drift if that default moves.
    .environment(\.appIdiom, .compact)
}

/// tv-idiom regression, two things at once:
/// 1. The scope chips are the FIRST thing in the scroll — in-content, so they scroll away with the
///    results, which the system `.searchScopes` bar could never do (it lives in the search
///    presentation layer). "Movies" is pre-selected so the filled-vs-glass chip contrast shows.
/// 2. The grids must carry the canonical 40pt focusable-tile gaps
///    (`AppLayout.posterGridColumn/RowSpacing`) plus the 40pt inter-section gap
///    (`focusSafeSectionGap`) — at the old hardcoded 12/18/26pt the system focus lift
///    (`hoverEffect(.highlight)`) on a result overlapped its neighbours and the next section's
///    header. A static render can't show the lift itself; what's under test is the resting gap.
#Preview("TV grid gaps", traits: .fixedLayout(width: 1920, height: 1080)) {
    @Previewable @State var scope: SearchScope = .movies
    let movies = (1...6).map { i in
        Movie(
            id: ItemID(rawValue: "m\(i)"), title: "Movie \(i)", overview: nil, year: 2019 + i,
            runtime: .seconds(6000), communityRating: nil, officialRating: nil, genres: [],
            primaryTag: nil, backdropTags: [], logoTag: nil, thumbTag: nil,
            userData: UserItemData(played: false, playbackPositionTicks: 0, playCount: 0, isFavorite: false)
        )
    }
    let results = AggregatedSearchResults(
        movies: movies.map { SourcedItem(item: .movie($0), source: .jellyfin(.preview)) },
        episodes: previewSearchEpisodes.prefix(3).map { SourcedItem(item: .episode($0), source: .jellyfin(.preview)) }
    )
    NavigationStack {
        // The real production composition on tvOS: `TVSearchScopeSurface` owns the scroll, the
        // margins, and the persistent chip row; these sections are just its content.
        TVSearchScopeSurface(scope: scope, showsScopes: true, isShowingSkeleton: false, onSelectScope: { scope = $0 }) {
            JellyfinSearchResultsView(results: results)
        }
    }
    .environment(PlaybackPresenter())
    .background(Color.background)
    .environment(\.colorScheme, .dark)
    // The ONLY idiom source now — the view and its `GridSection` children both read `\.appIdiom`
    // from here. Without it the preview renders the compact gaps and no chip row.
    .environment(\.appIdiom, .tv)
    // Wrapped in `.tint(Color.label)` to mirror RootView's global tint — environment parity with
    // production, not a chip dependency: every capsule paints its own fill (`chipRestFill` /
    // `chipSelectedFill`), so none of them rests on the inherited tint.
    .tint(Color.label)
}
#endif
