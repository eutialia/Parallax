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
    let onPlay: () -> Void
    let onToggleFavorite: () -> Void

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
            HStack(spacing: Space.s12) {
                PrimaryPlayButton(
                    title: entry.playButtonTitle,
                    fillWidth: false,
                    layoutReserveTitle: ItemPlayButtonLabel.layoutReserveTitle,
                    action: onPlay
                )
                FavoriteActionButton(isFavorite: isFavorite, action: onToggleFavorite)
            }
            .padding(.top, Space.s8)
        }
        .frame(maxWidth: HeroMetrics.contentMaxWidth, alignment: .leading)
    }

}
