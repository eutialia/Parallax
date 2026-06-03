import SwiftUI
import ParallaxJellyfin

extension View {
    /// The shared `ItemNavigation` push destination (movie → MovieDetailView,
    /// series → SeriesDetailView). Was copy-pasted in Home, Library, and Search.
    @ViewBuilder
    func itemNavigationDestination() -> some View {
        navigationDestination(for: ItemNavigation.self) { nav in
            switch nav {
            case .movie(let id, let session): MovieDetailView(itemID: id, session: session)
            case .series(let id, let session): SeriesDetailView(itemID: id, session: session)
            }
        }
    }
}

/// Wraps a tile with the right tap behavior for its item kind: an episode plays
/// directly (via the PlaybackPresenter); a movie/series pushes its detail screen.
/// Single source for the play-vs-navigate dispatch duplicated in Home + Library.
struct ItemNavigator<Label: View>: View {
    let item: Item
    let session: Session
    @ViewBuilder let label: () -> Label

    @Environment(PlaybackPresenter.self) private var playback

    var body: some View {
        switch item {
        case .episode(let e):
            Button { playback.play(e.id, in: session) } label: { label() }
                .buttonStyle(.plain)
        case .movie(let m):
            NavigationLink(value: ItemNavigation.movie(m.id, session)) { label() }
                .buttonStyle(.plain)
        case .series(let s):
            NavigationLink(value: ItemNavigation.series(s.id, session)) { label() }
                .buttonStyle(.plain)
        }
    }
}
