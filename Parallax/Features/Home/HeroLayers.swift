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
    let item: Item
    let session: Session
    let regularWidth: Bool
    let resumeEpisode: Episode?
    let isFavorite: Bool
    let onPlay: () -> Void
    let onToggleFavorite: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s12) {
            Text("NEWLY ADDED")
                .font(.caption.weight(.bold)).tracking(1.5)
                .foregroundStyle(.white.opacity(0.7))
            title
            if let meta {
                Text(meta).font(.subheadline).foregroundStyle(.white.opacity(0.85))
            }
            HStack(spacing: Space.s12) {
                PrimaryPlayButton(
                    title: ItemPlayButtonLabel.title(for: item, resumeEpisode: resumeEpisode),
                    fillWidth: false,
                    layoutReserveTitle: ItemPlayButtonLabel.layoutReserveTitle,
                    action: onPlay
                )
                FavoriteActionButton(isFavorite: isFavorite, action: onToggleFavorite)
            }
            .padding(.top, Space.s8)
        }
        .frame(maxWidth: HeroMetrics.contentMaxWidth, alignment: .leading)
        // Legibility over bright artwork without a boxed background (shared with HeroBackdrop).
        .modifier(HeroForegroundLegibility())
    }

    @ViewBuilder
    private var title: some View {
        if let ref = logoImageRef {
            JellyfinImage(ref: ref, kind: .logo, session: session, maxWidth: 800, style: .logo)
                .frame(height: regularWidth ? 96 : 60, alignment: .leading)
                .frame(maxWidth: HeroMetrics.contentMaxWidth, alignment: .leading)
                .accessibilityLabel(item.displayTitle)
        } else {
            Text(item.displayTitle)
                .scaledFont(regularWidth ? 52 : 32, relativeTo: .largeTitle, weight: .heavy)
                .foregroundStyle(.white).lineLimit(2).minimumScaleFactor(0.7)
        }
    }

    private var logoImageRef: ImageRef? {
        switch item {
        case .movie(let m): return m.imageRef(.logo)
        case .series(let s): return s.imageRef(.logo)
        case .episode: return nil
        }
    }

    private var meta: String? {
        switch item {
        case .movie(let m):
            var parts: [String] = []
            if let y = m.year { parts.append(String(y)) }
            if let r = m.runtime { parts.append("\(Int(r.components.seconds / 60)) min") }
            return parts.isEmpty ? nil : parts.joined(separator: " · ")
        case .series(let s): return s.year.map(String.init)
        case .episode(let e):
            if let season = e.parentIndexNumber, let idx = e.indexNumber { return "S\(season) · E\(idx)" }
            return nil
        }
    }
}
