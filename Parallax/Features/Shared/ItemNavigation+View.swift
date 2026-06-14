import SwiftUI
import ParallaxJellyfin

// MARK: - Detail navigation transition
//
// Movie/series detail is a NavigationStack push on every platform.
//
// iOS/iPadOS: a fluid zoom — the tapped card artwork expands into the detail layer
// (`.navigationTransition(.zoom)` + `matchedTransitionSource`).
//
// tvOS: no animated transition. SwiftUI won't animate a NavigationStack push/pop on tvOS (it's an
// instant cut) and `.zoom` is a no-op there. A state-driven crossfade *was* tried — it dissolved
// correctly but couldn't hold focus (the detail opens on a loading skeleton with no focusable view,
// so focus went nil: ~80% of the time Menu escaped the whole screen and the detail's buttons were
// dead). The system stack push manages focus and Menu-back for free, so we use it — the instant cut
// matches the rest of tvOS navigation (e.g. the library list → grid push) until Apple gives us an
// animatable stack transition there.

extension EnvironmentValues {
    /// Namespace for `matchedTransitionSource` / `.navigationTransition(.zoom)` in this stack.
    /// iOS/iPadOS-only effect; the key stays cross-platform because `MediaTile` reads it
    /// unconditionally (it's simply never honored on tvOS, where there's no zoom).
    @Entry var itemZoomNamespace: Namespace.ID? = nil

    /// Set on `NavigationLink` labels so `MediaTile` can mark its artwork (not the title row) as
    /// the zoom source. Inert on tvOS — the source modifier ignores it there.
    @Entry var itemZoomNavigationValue: ItemNavigation? = nil
}

extension View {
    /// Registers movie/series detail destinations and wires the transition: a zoom push on
    /// iOS/iPadOS, a plain push on tvOS (see the header).
    func itemDetailNavigation() -> some View {
        modifier(ItemDetailNavigationModifier())
    }

    /// Marks artwork (or a tile) as the zoom source for the given navigation value. iOS-only
    /// effect; inert on tvOS, but called unconditionally by `MediaTile`.
    func itemZoomTransitionSource(_ navigation: ItemNavigation) -> some View {
        modifier(ItemZoomTransitionSourceModifier(navigation: navigation))
    }
}

private struct ItemDetailNavigationModifier: ViewModifier {
    @Namespace private var namespace

    func body(content: Content) -> some View {
        content
            .environment(\.itemZoomNamespace, namespace)
            .navigationDestination(for: ItemNavigation.self) { nav in
                itemDetailDestination(nav)
                    #if !os(tvOS)
                    .navigationTransition(.zoom(sourceID: nav, in: namespace))
                    #endif
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

    func body(content: Content) -> some View {
        #if os(tvOS)
        // No zoom on tvOS (see header) — marking a source would be inert, so skip it.
        content
        #else
        sourced(content)
        #endif
    }

    #if !os(tvOS)
    @Environment(\.itemZoomNamespace) private var namespace

    @ViewBuilder
    private func sourced(_ content: Content) -> some View {
        if let namespace {
            content.matchedTransitionSource(id: navigation, in: namespace) { source in
                source.clipShape(.rect(cornerRadius: Radius.tile))
            }
        } else {
            content
        }
    }
    #endif
}

// MARK: - Item navigator

/// Wraps a tile with the right tap behavior for its item kind. An episode always plays directly
/// (via the `PlaybackPresenter`); a series always pushes its detail screen (it can't play without
/// first picking an episode); a movie does whichever `movieTap` specifies. Single source for the
/// play-vs-navigate dispatch reused across Home / Library / Search.
struct ItemNavigator<Label: View>: View {
    /// What tapping a *movie* tile does. Library and Search are browse-first, so they keep the
    /// detail push (the default). Home is play-first — its shelves are Continue Watching / Next
    /// Up — so it plays the movie immediately, resuming from saved progress like an episode.
    enum MovieTap {
        case opensDetail
        case plays
    }

    let item: Item
    let session: Session
    var movieTap: MovieTap = .opensDetail
    @ViewBuilder let label: () -> Label

    @Environment(PlaybackPresenter.self) private var playback

    var body: some View {
        switch item {
        case .episode(let e):
            playButton(e.id)
        case .movie(let m):
            switch movieTap {
            case .plays:       playButton(m.id)
            case .opensDetail: detailLink(.movie(m.id, session))
            }
        case .series(let s):
            detailLink(.series(s.id, session))
        }
    }

    /// Tap-to-play for a directly playable item (an episode, or a movie on a play-first surface).
    /// The player resolves the stream URL and resume position from the id under its loading veil —
    /// the same `.itemID` path episodes already use, so a half-watched movie resumes, not restarts.
    private func playButton(_ id: ItemID) -> some View {
        Button { playback.play(id, in: session) } label: { label() }
            .tvPosterButton()
    }

    private func detailLink(_ nav: ItemNavigation) -> some View {
        NavigationLink(value: nav) {
            label().environment(\.itemZoomNavigationValue, nav)
        }
        .tvPosterButton()
    }
}
