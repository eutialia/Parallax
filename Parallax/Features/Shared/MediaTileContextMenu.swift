import SwiftUI
import os
import ParallaxJellyfin
import ParallaxCore

// MARK: - Programmatic detail push

extension EnvironmentValues {
    /// Pushes a movie/series detail onto the enclosing stack WITHOUT a zoom transition — the escape
    /// hatch for controls that carry no `NavigationLink`/`matchedTransitionSource` to zoom from (the
    /// context menu's "Go to Series" / "View Details"). Wired by `itemDetailNavigation()` at each
    /// content stack's root (a plain push there — see `ItemDetailNavigationModifier`); the default
    /// no-op covers any view mounted outside such a stack. iOS/iPadOS-only in practice (tvOS attaches
    /// no context menus), but the key stays cross-platform so the shared menu builder needs no `#if os`.
    @Entry var pushItemDetail: (ItemNavigation) -> Void = { _ in }
}

// MARK: - Media-tile context menu

/// Per-surface flags that tune the shared media-tile menu. The menu is otherwise a pure function of
/// the tile's ARM (its tap behavior), not the screen — these cover only the two cases where two
/// surfaces share an arm yet differ: a play-first movie (Home) vs a browse-first one, and an episode
/// on a foreign screen vs on its own series' page.
struct MediaTileMenuContext {
    /// Home's Continue-Watching movie tiles PLAY on tap, so they get the play-first menu (View
    /// Details + Play from Beginning); Library/Search movies open detail on tap and get the
    /// detail-first menu (Play/Resume). Mirrors `ItemNavigator.MovieTap`.
    var moviePlaysOnTap: Bool = false
    /// Suppressed only on a series' OWN detail page, where "Go to Series" would push the page you're
    /// already on. Every other episode surface shows it.
    var showsGoToSeries: Bool = true
}

extension View {
    /// Attaches the system context menu (long-press) for a Jellyfin media tile, built per the item's
    /// arm (episode / play-first movie / detail-first movie / series) and wired to the shared
    /// `UserDataActions` service + the `PlaybackPresenter`. iOS/iPadOS only: tvOS is a bare passthrough
    /// (context menus are out of scope this wave and the focus engine owns long-press there), following
    /// the `pressableTileButton()` dispatcher precedent. Apply on the SAME view that wears
    /// `pressableTileButton()`, so the platter lifts the tile itself.
    @ViewBuilder
    func mediaTileContextMenu(
        item: Item,
        session: Session,
        context: MediaTileMenuContext = .init()
    ) -> some View {
        #if os(tvOS)
        self
        #else
        modifier(MediaTileContextMenuModifier(item: item, session: session, context: context))
        #endif
    }
}

#if !os(tvOS)
private struct MediaTileContextMenuModifier: ViewModifier {
    let item: Item
    let session: Session
    let context: MediaTileMenuContext

    func body(content: Content) -> some View {
        content
            // Lift the tile's own rounded silhouette, not a sharp-cornered snapshot, when the platter
            // raises the default preview — only the preview's corner shape is tuned (Radius.tile is the
            // clip MediaThumbnail draws with).
            .contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: Radius.tile, style: .continuous))
            // The menu's own View (not an inline builder) so its `@Environment(AppDependencies/…)`
            // reads resolve only when the menu is presented — a tile #Preview that never long-presses
            // needn't carry the whole dependency graph (the modifier itself reads no environment).
            .contextMenu { MediaTileMenuContent(item: item, session: session, context: context) }
    }
}

/// The menu body for `mediaTileContextMenu`. A standalone `View` so its environment reads are lazy
/// (resolved at present time, not at every tile render) — see the modifier's `.contextMenu` note.
private struct MediaTileMenuContent: View {
    let item: Item
    let session: Session
    let context: MediaTileMenuContext

    @Environment(AppDependencies.self) private var deps
    @Environment(PlaybackPresenter.self) private var playback
    @Environment(UserDataActions.self) private var userDataActions
    @Environment(\.pushItemDetail) private var pushItemDetail

    @ViewBuilder
    var body: some View {
        switch item {
        case .episode(let episode):
            episodeMenu(episode)
        case .movie(let movie):
            if context.moviePlaysOnTap { playFirstMovieMenu(movie) } else { detailFirstMovieMenu(movie) }
        case .series(let series):
            seriesMenu(series)
        }
    }

    // MARK: Per-arm menus

    /// A. Play-first episode tile (Home CW/Next Up, Search). A′ (series' own page) drops Go to Series.
    @ViewBuilder
    private func episodeMenu(_ episode: Episode) -> some View {
        if context.showsGoToSeries {
            Button {
                pushItemDetail(.series(episode.seriesID, .jellyfin(session)))
            } label: {
                Label("Go to Series", systemImage: "info.circle")
            }
        }
        if episode.userData.isInProgress {
            playFromBeginningButton(episode.id)
        }
        markWatchedButton(id: episode.id, played: episode.userData.played)
    }

    /// B. Play-first movie tile (Home Continue Watching).
    @ViewBuilder
    private func playFirstMovieMenu(_ movie: Movie) -> some View {
        Button {
            pushItemDetail(.movie(movie.id, .jellyfin(session)))
        } label: {
            Label("View Details", systemImage: "info.circle")
        }
        if movie.userData.isInProgress {
            playFromBeginningButton(movie.id)
        }
        favoriteButton(id: movie.id, isFavorite: movie.userData.isFavorite)
        markWatchedButton(id: movie.id, played: movie.userData.played)
    }

    /// C. Detail-first movie tile (Library grid, Search, other Home shelves) — tap opens detail, so
    /// the menu carries the play action instead: Resume mid-watch, else Play (normal resume semantics).
    @ViewBuilder
    private func detailFirstMovieMenu(_ movie: Movie) -> some View {
        Button {
            playback.play(movie.id, in: session)
        } label: {
            Label(movie.userData.isInProgress ? "Resume" : "Play", systemImage: "play.fill")
        }
        favoriteButton(id: movie.id, isFavorite: movie.userData.isFavorite)
        markWatchedButton(id: movie.id, played: movie.userData.played)
    }

    /// D. Series tile (always detail-first). "All" is deliberate honesty about the server-side cascade
    /// to every episode; Task 2's operation-tagged event makes Home/detail react.
    @ViewBuilder
    private func seriesMenu(_ series: Series) -> some View {
        favoriteButton(id: series.id, isFavorite: series.userData.isFavorite)
        Button {
            Task { await togglePlayed(id: series.id, currentlyPlayed: series.userData.played) }
        } label: {
            Label(
                series.userData.played ? "Mark All Unwatched" : "Mark All Watched",
                systemImage: series.userData.played ? "minus.circle" : "checkmark.circle"
            )
        }
    }

    // MARK: Shared menu buttons

    private func playFromBeginningButton(_ id: ItemID) -> some View {
        Button {
            playback.play(id, in: session, fromBeginning: true)
        } label: {
            Label("Play from Beginning", systemImage: "gobackward")
        }
    }

    private func favoriteButton(id: ItemID, isFavorite: Bool) -> some View {
        Button {
            Task { await toggleFavorite(id: id, currentlyFavorite: isFavorite) }
        } label: {
            Label(
                isFavorite ? "Remove from Favorites" : "Add to Favorites",
                systemImage: isFavorite ? "heart.slash" : "heart"
            )
        }
    }

    private func markWatchedButton(id: ItemID, played: Bool) -> some View {
        Button {
            Task { await togglePlayed(id: id, currentlyPlayed: played) }
        } label: {
            Label(
                played ? "Mark as Unwatched" : "Mark as Watched",
                systemImage: played ? "minus.circle" : "checkmark.circle"
            )
        }
    }

    // MARK: Actions

    /// No per-tile optimistic state: Task 2's change events repaint every visible surface on success.
    /// On failure we only log — matching the movie/series detail VMs (`Log.ui.error`, no user-facing
    /// alert), the dominant idiom and the one covering the played toggles the menu introduces.
    private func toggleFavorite(id: ItemID, currentlyFavorite: Bool) async {
        let repo = await deps.jellyfinLibraryRepoFactory(session)
        if case .failure(let error) = await userDataActions.toggleFavorite(itemID: id, currentlyFavorite: currentlyFavorite, via: repo) {
            Log.ui.error("menu toggleFavorite failed: \(error.userMessage) (\(error.networkDiagnostic))")
        }
    }

    private func togglePlayed(id: ItemID, currentlyPlayed: Bool) async {
        let repo = await deps.jellyfinLibraryRepoFactory(session)
        if case .failure(let error) = await userDataActions.togglePlayed(itemID: id, currentlyPlayed: currentlyPlayed, via: repo) {
            Log.ui.error("menu togglePlayed failed: \(error.userMessage) (\(error.networkDiagnostic))")
        }
    }
}
#endif
