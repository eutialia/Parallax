import SwiftUI
import ParallaxJellyfin
import ParallaxCore
import ParallaxFeatures

// MARK: - Programmatic detail push

/// Pushes a movie/series detail onto the enclosing stack WITHOUT a zoom transition — the escape
/// hatch for controls that carry no `NavigationLink`/`matchedTransitionSource` to zoom from (the
/// context menu's "Go to Series" / "View Details"). Wired by `itemDetailNavigation()` at each
/// content stack's root (a plain push there — see `ItemDetailNavigationModifier`); the default
/// no-op covers any view mounted outside such a stack.
///
/// Equal by `stack`, not by closure: the closure writes the owning root's `@State`, so every
/// action one root hands out is interchangeable, and a bare closure would invalidate every tile
/// reading it each time that root re-renders.
struct PushItemDetailAction: Equatable {
    let stack: Namespace.ID?
    let push: (ItemNavigation) -> Void

    func callAsFunction(_ navigation: ItemNavigation) { push(navigation) }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.stack == rhs.stack }
}

extension EnvironmentValues {
    @Entry var pushItemDetail = PushItemDetailAction(stack: nil) { _ in }
}

// MARK: - Media-tile context menu

extension View {
    /// Attaches the system context menu (long-press) for a Jellyfin media tile, built per the item's
    /// arm (episode / play-first movie / detail-first movie / series) and wired to the shared
    /// `UserDataActions` service + the `PlaybackPresenter`. All platforms: touch long-press lifts the
    /// preview platter on iOS/iPadOS; holding select on the focused tile anchors the system menu
    /// beside the lifted tile on tvOS. Apply on the SAME view that wears `pressableTileButton()`,
    /// so the platter lifts the tile itself.
    func mediaTileContextMenu(
        item: Item,
        session: Session,
        context: MediaTileMenuContext = .init()
    ) -> some View {
        modifier(MediaTileContextMenuModifier(item: item, session: session, context: context))
    }
}

private struct MediaTileContextMenuModifier: ViewModifier {
    let item: Item
    let session: Session
    let context: MediaTileMenuContext

    func body(content: Content) -> some View {
        content
            #if !os(tvOS)
            // Lift the tile's own rounded silhouette, not a sharp-cornered snapshot, when the platter
            // raises the default preview — only the preview's corner shape is tuned (Radius.tile is the
            // clip MediaThumbnail draws with). tvOS needs no shaping: the focus lift already carries
            // the tile's silhouette, and `.contextMenuPreview` isn't in its SDK.
            .contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: Radius.tile, style: .continuous))
            #endif
            // The menu's own View (not an inline builder) so its `@Environment(AppModel.self)`
            // read resolves only when the menu is presented — a tile #Preview that never long-presses
            // needn't carry the whole dependency graph (the modifier itself reads no environment).
            .contextMenu { MediaTileMenuContent(item: item, session: session, context: context) }
    }
}

/// The menu body for `mediaTileContextMenu`: `MediaTileMenuAction.menu` decides the entries, this
/// renders them. A standalone `View` so its environment reads are lazy (resolved at present time,
/// not at every tile render) — see the modifier's `.contextMenu` note.
private struct MediaTileMenuContent: View {
    let item: Item
    let session: Session
    let context: MediaTileMenuContext

    @Environment(AppModel.self) private var app
    @Environment(\.pushItemDetail) private var pushItemDetail

    var body: some View {
        ForEach(MediaTileMenuAction.menu(for: item, on: session, context: context), id: \.self) { action in
            Button {
                switch action {
                case .goToSeries(let navigation), .viewDetails(let navigation):
                    pushItemDetail(navigation)
                default:
                    Task { await app.perform(action, on: session) }
                }
            } label: {
                label(for: action)
            }
        }
    }

    private func label(for action: MediaTileMenuAction) -> Label<Text, Image> {
        switch action {
        case .goToSeries:
            Label("Go to Series", systemImage: "info.circle")
        case .viewDetails:
            Label("View Details", systemImage: "info.circle")
        case .play(_, let resumes):
            Label(resumes ? "Resume" : "Play", systemImage: "play.fill")
        case .playFromBeginning:
            Label("Play from Beginning", systemImage: "gobackward")
        case .toggleFavorite(_, let isFavorite):
            Label(
                isFavorite ? "Remove from Favorites" : "Add to Favorites",
                systemImage: isFavorite ? "heart.slash" : "heart"
            )
        case .togglePlayed(_, let played):
            Label(
                played ? "Mark as Unwatched" : "Mark as Watched",
                systemImage: played ? "minus.circle" : "checkmark.circle"
            )
        case .toggleSeriesPlayed(_, let played):
            Label(
                played ? "Mark All Unwatched" : "Mark All Watched",
                systemImage: played ? "minus.circle" : "checkmark.circle"
            )
        }
    }
}
