import ParallaxCore
import ParallaxJellyfin

/// What tapping a Jellyfin media tile does. An episode always plays directly; a series always opens
/// its detail (it can't play without first picking an episode); a movie does whichever the surface
/// asks for. Single source for the play-vs-navigate dispatch reused across Home / Library / Search.
public nonisolated enum MediaTileTap: Hashable, Sendable {
    case play(ItemID)
    case openDetail(ItemNavigation)

    /// - Parameter moviePlays: Home is play-first — its shelves are Continue Watching / Next Up —
    ///   so a movie plays immediately, resuming from saved progress like an episode. Library and
    ///   Search are browse-first and open the detail.
    public static func resolve(_ item: Item, on session: Session, moviePlays: Bool) -> MediaTileTap {
        switch item {
        case .episode(let episode):
            .play(episode.id)
        case .movie(let movie):
            moviePlays ? .play(movie.id) : .openDetail(.movie(movie.id, .jellyfin(session)))
        case .series(let series):
            .openDetail(.series(series.id, .jellyfin(session)))
        }
    }
}

/// Per-surface flags that tune the shared media-tile menu. The menu is otherwise a pure function of
/// the tile's ARM (its tap behavior), not the screen — these cover only the two cases where two
/// surfaces share an arm yet differ: a play-first movie (Home) vs a browse-first one, and an episode
/// on a foreign screen vs on its own series' page.
public nonisolated struct MediaTileMenuContext: Sendable {
    /// Home's Continue-Watching movie tiles PLAY on tap, so they get the play-first menu (View
    /// Details + Play from Beginning); Library/Search movies open detail on tap and get the
    /// detail-first menu (Play/Resume). Mirrors `MediaTileTap.resolve(_:on:moviePlays:)`.
    public var moviePlaysOnTap: Bool
    /// Suppressed only on a series' OWN detail page, where "Go to Series" would push the page you're
    /// already on. Every other episode surface shows it.
    public var showsGoToSeries: Bool

    public init(moviePlaysOnTap: Bool = false, showsGoToSeries: Bool = true) {
        self.moviePlaysOnTap = moviePlaysOnTap
        self.showsGoToSeries = showsGoToSeries
    }
}

/// One entry of a media tile's long-press menu. The view renders each as a button; the navigation
/// entries push through the view's stack, and `AppModel.perform(_:on:)` runs the rest.
public nonisolated enum MediaTileMenuAction: Hashable, Sendable {
    case goToSeries(ItemNavigation)
    case viewDetails(ItemNavigation)
    /// Plays with normal resume semantics; `resumes` picks the "Resume" copy.
    case play(ItemID, resumes: Bool)
    case playFromBeginning(ItemID)
    case toggleFavorite(ItemID, isFavorite: Bool)
    case togglePlayed(ItemID, played: Bool)
    /// "All" is deliberate honesty about the server-side cascade to every episode.
    case toggleSeriesPlayed(ItemID, played: Bool)

    /// The menu for `item`, in display order, built per the item's arm.
    public static func menu(
        for item: Item,
        on session: Session,
        context: MediaTileMenuContext = .init()
    ) -> [MediaTileMenuAction] {
        let source: LibrarySource = .jellyfin(session)
        switch item {
        case .episode(let episode):
            // A′ (the series' own page) drops Go to Series.
            return (context.showsGoToSeries ? [.goToSeries(.series(episode.seriesID, source))] : [])
                + (episode.userData.isInProgress ? [.playFromBeginning(episode.id)] : [])
                + [.togglePlayed(episode.id, played: episode.userData.played)]
        case .movie(let movie) where context.moviePlaysOnTap:
            return [.viewDetails(.movie(movie.id, source))]
                + (movie.userData.isInProgress ? [.playFromBeginning(movie.id)] : [])
                + [
                    .toggleFavorite(movie.id, isFavorite: movie.userData.isFavorite),
                    .togglePlayed(movie.id, played: movie.userData.played),
                ]
        case .movie(let movie):
            // Tap opens detail, so the menu carries the play action instead.
            return [
                .play(movie.id, resumes: movie.userData.isInProgress),
                .toggleFavorite(movie.id, isFavorite: movie.userData.isFavorite),
                .togglePlayed(movie.id, played: movie.userData.played),
            ]
        case .series(let series):
            return [
                .toggleFavorite(series.id, isFavorite: series.userData.isFavorite),
                .toggleSeriesPlayed(series.id, played: series.userData.played),
            ]
        }
    }
}
