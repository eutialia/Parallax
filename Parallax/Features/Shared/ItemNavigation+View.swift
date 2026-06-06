import SwiftUI
import ParallaxJellyfin

// MARK: - Zoom navigation (Apple TV–style card → full-screen detail)

private enum ItemZoomNamespaceKey: EnvironmentKey {
    static let defaultValue: Namespace.ID? = nil
}

/// Set on `NavigationLink` labels so `MediaTile` can mark its artwork (not the title row) as the zoom source.
private enum ItemZoomNavigationValueKey: EnvironmentKey {
    static let defaultValue: ItemNavigation? = nil
}

extension EnvironmentValues {
    /// Namespace for `matchedTransitionSource` / `.navigationTransition(.zoom)` in this stack.
    var itemZoomNamespace: Namespace.ID? {
        get { self[ItemZoomNamespaceKey.self] }
        set { self[ItemZoomNamespaceKey.self] = newValue }
    }

    /// When set by `ItemNavigator`, `MediaTile` uses this to mark its artwork as the zoom source.
    var itemZoomNavigationValue: ItemNavigation? {
        get { self[ItemZoomNavigationValueKey.self] }
        set { self[ItemZoomNavigationValueKey.self] = newValue }
    }
}

extension View {
    /// Registers movie/series detail destinations and wires the fluid zoom transition
    /// (card artwork expands into the detail layer instead of sliding in from the trailing edge).
    func itemZoomNavigation() -> some View {
        modifier(ItemZoomNavigationModifier())
    }

    /// Marks artwork (or a tile) as the zoom source for the given navigation value.
    func itemZoomTransitionSource(_ navigation: ItemNavigation) -> some View {
        modifier(ItemZoomTransitionSourceModifier(navigation: navigation))
    }
}

private struct ItemZoomNavigationModifier: ViewModifier {
    @Namespace private var namespace

    func body(content: Content) -> some View {
        content
            .environment(\.itemZoomNamespace, namespace)
            .navigationDestination(for: ItemNavigation.self) { nav in
                itemDetailDestination(nav)
                    .appScreenBackground()
                    .navigationTransition(.zoom(sourceID: nav, in: namespace))
            }
    }

    @ViewBuilder
    private func itemDetailDestination(_ nav: ItemNavigation) -> some View {
        switch nav {
        case .movie(let id, let session): MovieDetailView(itemID: id, session: session)
        case .series(let id, let session): SeriesDetailView(itemID: id, session: session)
        }
    }
}

private struct ItemZoomTransitionSourceModifier: ViewModifier {
    let navigation: ItemNavigation
    @Environment(\.itemZoomNamespace) private var namespace

    func body(content: Content) -> some View {
        if let namespace {
            content.matchedTransitionSource(id: navigation, in: namespace) { source in
                source.clipShape(.rect(cornerRadius: Radius.tile))
            }
        } else {
            content
        }
    }
}

// MARK: - Item navigator

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
            let nav = ItemNavigation.movie(m.id, session)
            NavigationLink(value: nav) {
                label().environment(\.itemZoomNavigationValue, nav)
            }
            .buttonStyle(.plain)
        case .series(let s):
            let nav = ItemNavigation.series(s.id, session)
            NavigationLink(value: nav) {
                label().environment(\.itemZoomNavigationValue, nav)
            }
            .buttonStyle(.plain)
        }
    }
}
