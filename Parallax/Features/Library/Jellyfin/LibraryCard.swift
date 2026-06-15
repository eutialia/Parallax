import SwiftUI
import ParallaxJellyfin
import ParallaxCore

/// One tile in the Library list. Two flavors share the same 16:9 footprint, corner, and
/// frosted type-glyph chip so the grid scans as one family:
/// - `init(collection:session:)` — a Jellyfin banner (the library name is baked into the
///   server art), topped with the chip. No text label of its own; the name rides VoiceOver.
/// - `init(smb:)` — an SMB library, which has no server-provided banner art, so it paints a
///   neutral field (matching `FavoritesCard`) with the name set in text where the banner
///   would carry it. Placeholder-quality visuals — to be refined on-device.
/// Tapping either drills into the library's grid.
struct LibraryCard: View {
    private enum Kind {
        /// Jellyfin: render the server banner behind the chip.
        case jellyfin(session: Session)
        /// SMB: no remote art, so paint a neutral field and set the name in text.
        case smb(name: String)
    }

    private let collection: MediaCollection
    private let kind: Kind

    /// Jellyfin banner card — needs the session to fetch the 16:9 library art.
    init(collection: MediaCollection, session: Session) {
        self.collection = collection
        self.kind = .jellyfin(session: session)
    }

    /// Neutral SMB card — no session/remote art. Mirrors `FavoritesCard`'s self-painted field
    /// so the SMB libraries sit in the same grid family as the Jellyfin banners.
    init(smb collection: MediaCollection) {
        self.collection = collection
        self.kind = .smb(name: collection.name)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            background
            // A frosted type-glyph chip is the one piece of chrome shared across all card
            // flavors — a glanceable cue for libraries whose art is a generic collage.
            Image(systemName: collection.collectionType.symbolName)
                .scaledFont(16, relativeTo: .headline, weight: .semibold).foregroundStyle(.white)
                .frame(width: 36, height: 36)
                // Same dark frosted Liquid Glass as the hero's photo-context chrome — this
                // chip floats on artwork too (it was the app's one `.ultraThinMaterial` chip).
                .glassEffect(.regular.tint(Color.heroGlass), in: .rect(cornerRadius: 10, style: .continuous))
                .environment(\.colorScheme, .dark)
                .padding(Space.s14)
            // SMB has no baked-in name, so set it in text where the banner art would carry it
            // (mirrors FavoritesCard). The Jellyfin banner already shows the name in its art.
            if case .smb(let name) = kind {
                Text(name)
                    .scaledFont(22, relativeTo: .title3, weight: .bold)
                    .foregroundStyle(Color.label)
                    .lineLimit(2)
                    .padding(Space.s14)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            }
        }
        // Pin the card to the banner aspect so a library with no Primary image keeps full
        // height (and a tappable contentShape) instead of collapsing.
        .aspectRatio(MediaImage.landscape, contentMode: .fit)
        .clipShape(.rect(cornerRadius: Radius.card))
        .contentShape(.rect(cornerRadius: Radius.card))
        // tvOS system highlight masked to the banner's corners — pairs with the
        // `.borderless` style on the enclosing NavigationLink (`tvPosterButton`).
        .tvPosterHighlight(cornerRadius: Radius.card)
        .shadow(color: .black.opacity(0.2), radius: 8, y: 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(collection.name)
    }

    @ViewBuilder
    private var background: some View {
        switch kind {
        case .jellyfin(let session):
            MediaImage(jellyfin: collection.imageRef(.primary), session: session,
                       maxWidth: 1200, aspectRatio: MediaImage.landscape)
        case .smb:
            // Neutral field + oversized glyph watermark so the tile doesn't read as a loading
            // placeholder — same recipe as FavoritesCard's quiet card.
            Rectangle()
                .fill(Color.fill)
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: "externaldrive.connected.to.line.below.fill")
                        .font(.system(size: 92))
                        .foregroundStyle(Color.label.opacity(0.07))
                        .rotationEffect(.degrees(-10))
                        .offset(x: 16, y: 22)
                }
        }
    }
}
