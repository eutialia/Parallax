import SwiftUI
import ParallaxJellyfin
import ParallaxCore

/// The search results grid, split out as an `Equatable` view so typing can't re-render it.
///
/// The search field's text lives in the parent's `@State`, so every keystroke re-evaluates
/// the parent body — which previously rebuilt every `MediaTile` and made typing lag.
/// Wrapping the grid in `.equatable()` lets SwiftUI skip it whenever `results`, `session`,
/// and the column counts are unchanged — i.e. on every keystroke that doesn't change the
/// results. Keep this view free of `@Environment` reads the body renders from, or the
/// `==` skip would serve a stale snapshot (dispatch goes through `ItemNavigator`, which
/// owns its own playback/navigation environment).
struct JellyfinSearchResultsView: View, Equatable {
    let results: SearchResults
    let session: Session
    /// Passed as a plain value from the parent (not an `@Environment` read)
    /// to keep the `==` skip honest; every layout metric derives from it.
    let idiom: AppIdiom

    static func == (lhs: JellyfinSearchResultsView, rhs: JellyfinSearchResultsView) -> Bool {
        lhs.results == rhs.results
            && lhs.session == rhs.session
            && lhs.idiom == rhs.idiom
    }

    private var posterCols: Int { AppLayout.searchPosterColumns(idiom: idiom) }
    private var landscapeCols: Int { AppLayout.searchLandscapeColumns(idiom: idiom) }
    private var hMargin: CGFloat { AppLayout.contentHMargin(idiom: idiom) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.s26) {
                if !results.series.isEmpty {
                    gridSection("Shows", count: results.series.count, cols: posterCols) {
                        ForEach(results.series) { s in
                            ItemNavigator(item: .series(s), session: session) {
                                MediaTile(title: s.title, imageRef: s.imageRef(.primary), session: session, watched: .init(.series(s)), aspectRatio: MediaImage.poster, maxImageWidth: 400)
                            }
                        }
                    }
                }
                if !results.movies.isEmpty {
                    gridSection("Movies", count: results.movies.count, cols: posterCols) {
                        ForEach(results.movies) { m in
                            ItemNavigator(item: .movie(m), session: session) {
                                MediaTile(title: m.title, imageRef: m.imageRef(.primary), session: session, watched: .init(.movie(m)), aspectRatio: MediaImage.poster, maxImageWidth: 400)
                            }
                        }
                    }
                }
                if !results.episodes.isEmpty {
                    gridSection("Episodes", count: results.episodes.count, cols: landscapeCols) {
                        ForEach(results.episodes) { e in
                            ItemNavigator(item: .episode(e), session: session) {
                                // Episodes need the detail row a poster doesn't: neither the still
                                // nor the episode name says which show this is. `.lockup()` so the
                                // tvOS focus lift nudges that row aside instead of landing on it.
                                MediaTile(
                                    title: e.name, imageRef: e.stillFirstImageRef, session: session,
                                    watched: .init(.episode(e)), aspectRatio: MediaImage.landscape, maxImageWidth: 500,
                                    metadata: .init(leading: e.seriesContextCaption, trailing: e.timeCaption())
                                )
                                .lockup()
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, hMargin)
            .padding(.vertical, Space.s18)
        }
    }

    @ViewBuilder
    private func gridSection<Content: View>(_ title: String, count: Int, cols: Int, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Space.s12) {
            HStack(spacing: 6) {
                Text(title).font(.cardHeaderTitle)
                Text("\(count)").font(.subheadline).foregroundStyle(Color.secondaryLabel)
            }
            // One header stop: VoiceOver reads "Shows, 5 results" instead of "Shows" then a stray "5".
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(title), \(count) result\(count == 1 ? "" : "s")")
            .accessibilityAddTraits(.isHeader)
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
    let results = SearchResults(movies: [], series: [], episodes: previewSearchEpisodes)
    NavigationStack {
        JellyfinSearchResultsView(results: results, session: .preview, idiom: .compact)
    }
    .environment(PlaybackPresenter())
    .background(Color.background)
}

/// tv-idiom regression: the grids must carry the canonical 40pt focusable-tile gaps
/// (`AppLayout.posterGridColumn/RowSpacing`) — at the old hardcoded 12/18pt the system
/// focus lift (`hoverEffect(.highlight)`) on a result overlapped its neighbours. A static
/// render can't show the lift itself; what's under test is the resting gap it needs.
#Preview("TV grid gaps", traits: .fixedLayout(width: 1920, height: 1080)) {
    let movies = (1...6).map { i in
        Movie(
            id: ItemID(rawValue: "m\(i)"), title: "Movie \(i)", overview: nil, year: 2019 + i,
            runtime: .seconds(6000), communityRating: nil, officialRating: nil, genres: [],
            primaryTag: nil, backdropTags: [], logoTag: nil, thumbTag: nil,
            userData: UserItemData(played: false, playbackPositionTicks: 0, playCount: 0, isFavorite: false)
        )
    }
    let results = SearchResults(movies: movies, series: [], episodes: Array(previewSearchEpisodes.prefix(3)))
    NavigationStack {
        JellyfinSearchResultsView(results: results, session: .preview, idiom: .tv)
    }
    .environment(PlaybackPresenter())
    .background(Color.background)
    .environment(\.colorScheme, .dark)
}
#endif
