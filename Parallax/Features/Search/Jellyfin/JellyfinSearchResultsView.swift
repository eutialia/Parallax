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
    let posterCols: Int
    let landscapeCols: Int
    /// `AppLayout.contentHMargin` from the parent — passed as a plain value
    /// (not an `@Environment` idiom read) to keep the `==` skip honest.
    let hMargin: CGFloat

    static func == (lhs: JellyfinSearchResultsView, rhs: JellyfinSearchResultsView) -> Bool {
        lhs.results == rhs.results
            && lhs.session == rhs.session
            && lhs.posterCols == rhs.posterCols
            && lhs.landscapeCols == rhs.landscapeCols
            && lhs.hMargin == rhs.hMargin
    }

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
                                MediaTile(title: e.name, imageRef: e.imageRef(.primary), session: session, watched: .init(.episode(e)), aspectRatio: MediaImage.landscape, maxImageWidth: 500)
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
            LazyVGrid(columns: posterGridColumns(fixedColumns: cols, columnMinWidth: 0), spacing: Space.s18) {
                content()
            }
        }
    }
}
