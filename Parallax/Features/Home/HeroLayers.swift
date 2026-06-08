import SwiftUI
import ParallaxJellyfin

/// Full-bleed artwork for one hero item — the crossfading layers inside `CrossfadeArtwork`,
/// which stacks two of these and carries the iPad sidebar `backgroundExtensionEffect`.
struct HeroArtwork: View {
    let item: Item
    let session: Session
    let regularWidth: Bool

    private var artwork: (ref: ImageRef?, kind: ImageKind) {
        item.heroArtwork(regularWidth: regularWidth)
    }

    var body: some View {
        JellyfinImage(
            ref: artwork.ref,
            kind: artwork.kind,
            session: session,
            maxWidth: 1600,
            aspectRatio: HeroMetrics.bandAspectRatio(regularWidth: regularWidth),
            style: .fill
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }
}

/// The hero's title block + actions. `HomeHeroCarousel` inserts/removes this as a single
/// overlay (it isn't part of the crossfading artwork) so the Play / Favorite buttons stay
/// anchored and just re-bind to whichever item is settled — chrome, not page content.
struct HeroForeground: View {
    let entry: HomeHeroFeedEntry
    let session: Session
    let regularWidth: Bool
    let isFavorite: Bool
    /// Bound to the carousel's `@FocusState` so it can pull tvOS launch focus onto Play
    /// (out of the `.sidebarAdaptable` menu). Only consumed on tvOS; inert on iOS.
    var playFocus: FocusState<Bool>.Binding
    let onPlay: () -> Void
    let onToggleFavorite: () -> Void

    @Environment(\.appIdiom) private var idiom

    private var item: Item { entry.presentation }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s12) {
            Text(entry.eyebrow.rawValue)
                .font(.caption.weight(.bold))
                .tracking(1.5)
                .foregroundStyle(.white)
                .padding(.horizontal, Space.s12)
                .padding(.vertical, Space.s3)
                .background(.black.opacity(0.5), in: Capsule())
                .overlay(Capsule().strokeBorder(.white.opacity(0.35), lineWidth: 1))
            HeroTitle(item: item, session: session, regularWidth: regularWidth)
            if let overview = HeroOverview(item: item, regularWidth: regularWidth) {
                overview
            } else if let meta = item.heroMetadataLine {
                Text(meta)
                    .font(.subheadline)
                    .foregroundStyle(.white)
            }
            actionRow
        }
        .frame(maxWidth: HeroMetrics.contentMaxWidth, alignment: .leading)
    }

    /// Play + Favorite, side by side on every idiom. On tvOS the remote pages the carousel from
    /// the row's OUTER edges: pressing left while Play (leftmost) is focused, or right while
    /// Favorite (rightmost) is focused, has no focus neighbour in that direction, so the move
    /// falls through to `HomeHeroCarousel.onMoveCommand`. Pressing toward the centre just moves
    /// focus between the two buttons. iPhone/iPad page via the pan gesture instead.
    ///
    /// No `layoutReserveTitle` here (unlike the detail screens): each hero entry carries its own
    /// title, so the pill hugs it rather than reserving the widest "Resume S9 E9" width — the
    /// carousel's settle animation smooths the small per-page width change.
    private var actionRow: some View {
        HStack(spacing: idiom == .tv ? Space.s18 : Space.s12) {
            primaryPlay
            FavoriteActionButton(isFavorite: isFavorite, action: onToggleFavorite)
        }
        .padding(.top, Space.s8)
    }

    @ViewBuilder
    private var primaryPlay: some View {
        let button = PrimaryPlayButton(
            title: entry.playButtonTitle,
            fillWidth: false,
            action: onPlay
        )
        #if os(tvOS)
        button.focused(playFocus)
        #else
        button
        #endif
    }

}
