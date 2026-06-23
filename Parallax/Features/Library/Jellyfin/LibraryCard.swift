import SwiftUI
import ParallaxJellyfin
import ParallaxCore

/// Shared 16:9 library-banner chrome — the frosted type-glyph chip, an optional name set in text, an
/// optional oversized watermark, and the outer aspect / clip / focus-highlight / shadow chain. The
/// three card flavors (Jellyfin banner, SMB library, the virtual Favorites grid) differ ONLY in their
/// background field, chip/watermark glyph, and name, so they compose this instead of each re-rolling
/// ~35 lines of identical chrome (which previously drifted across `LibraryCard` and `FavoritesCard`).
struct LibraryBannerCard<Background: View>: View {
    /// Leading frosted chip glyph (a collection-type symbol, or "heart" for Favorites).
    let chipGlyph: String
    /// Name painted bottom-leading. nil when the background art already carries it (Jellyfin banners).
    let displayName: String?
    /// VoiceOver label — always the library's name, even when `displayName` is nil (Jellyfin).
    let accessibilityName: String
    /// Oversized corner watermark for the self-painted cards (SMB / Favorites); nil for banner art.
    let watermark: (glyph: String, size: CGFloat)?
    @ViewBuilder let background: Background

    var body: some View {
        ZStack(alignment: .topLeading) {
            background
                .overlay(alignment: .bottomTrailing) {
                    if let watermark {
                        // Quiet watermark so the tile doesn't read as a loading placeholder.
                        Image(systemName: watermark.glyph)
                            .font(.system(size: watermark.size))
                            .foregroundStyle(Color.label.opacity(0.07))
                            .rotationEffect(.degrees(-10))
                            .offset(x: 16, y: 22)
                    }
                }
            // A frosted type-glyph chip is the one piece of chrome shared across all flavors — a
            // glanceable cue for libraries whose art is a generic collage. Same dark frosted Liquid
            // Glass as the hero's photo-context chrome (this chip floats on artwork too).
            Image(systemName: chipGlyph)
                .scaledFont(16, relativeTo: .headline, weight: .semibold).foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .glassEffect(.regular.tint(Color.heroGlass), in: .rect(cornerRadius: Radius.chip, style: .continuous))
                .environment(\.colorScheme, .dark)
                .padding(Space.s14)
            // Self-painted cards set the name in text where the banner art would carry it.
            if let displayName {
                Text(displayName)
                    .scaledFont(22, relativeTo: .title3, weight: .bold)
                    .foregroundStyle(Color.label)
                    .lineLimit(2)
                    .padding(Space.s14)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            }
        }
        // Pin to the banner aspect so a library with no Primary image keeps full height (and a tappable
        // contentShape) instead of collapsing.
        .aspectRatio(MediaImage.landscape, contentMode: .fit)
        .clipShape(.rect(cornerRadius: Radius.card))
        .contentShape(.rect(cornerRadius: Radius.card))
        // tvOS system highlight masked to the banner's corners — pairs with `.borderless` (`tvPosterButton`).
        .tvPosterHighlight(cornerRadius: Radius.card)
        // The single sanctioned chrome shadow (DESIGN.md shadow vocabulary), under 16:9 banners.
        .shadow(color: .black.opacity(0.2), radius: 8, y: 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityName)
    }
}

/// One library tile in the Library list. Two flavors share `LibraryBannerCard`'s chrome:
/// - `init(collection:session:)` — a Jellyfin banner (the library name is baked into the server art),
///   topped with the chip. No text label of its own; the name rides VoiceOver.
/// - `init(smb:)` — an SMB library, which has no server-provided banner art, so it paints a neutral
///   field (matching `FavoritesCard`) with the name set in text where the banner would carry it.
/// Tapping either drills into the library's grid.
struct LibraryCard: View {
    private enum Kind {
        case jellyfin(Session)
        case smb
    }

    private let collection: MediaCollection
    private let kind: Kind

    /// Jellyfin banner card — needs the session to fetch the 16:9 library art.
    init(collection: MediaCollection, session: Session) {
        self.collection = collection
        self.kind = .jellyfin(session)
    }

    /// Neutral SMB card — no session/remote art. Mirrors `FavoritesCard`'s self-painted field.
    init(smb collection: MediaCollection) {
        self.collection = collection
        self.kind = .smb
    }

    var body: some View {
        switch kind {
        case .jellyfin(let session):
            LibraryBannerCard(
                chipGlyph: collection.collectionType.symbolName,
                displayName: nil,                       // baked into the banner art
                accessibilityName: collection.name,
                watermark: nil
            ) {
                MediaImage(jellyfin: collection.imageRef(.primary), session: session,
                           maxWidth: 1200, aspectRatio: MediaImage.landscape)
            }
        case .smb:
            LibraryBannerCard(
                chipGlyph: collection.collectionType.symbolName,
                displayName: collection.name,
                accessibilityName: collection.name,
                watermark: ("externaldrive.connected.to.line.below.fill", 92)
            ) {
                Rectangle().fill(Color.fill)
            }
        }
    }
}
