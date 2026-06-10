import SwiftUI
import ParallaxJellyfin

/// One tile in the Library list: a 16:9 Jellyfin banner (the library name is baked into the
/// art) topped with a frosted type-glyph chip. Shows no text label of its own — the name
/// rides VoiceOver via the accessibility label. Tapping it drills into the library's grid.
struct LibraryCard: View {
    let collection: MediaCollection
    let session: Session

    var body: some View {
        ZStack(alignment: .topLeading) {
            JellyfinImage(ref: collection.imageRef(.primary), kind: .primary, session: session,
                          maxWidth: 1200, aspectRatio: JellyfinImage.landscape)
            // A frosted type-glyph chip is the one piece of chrome — a glanceable cue for
            // libraries whose art is a generic collage with no obvious type.
            Image(systemName: collection.collectionType.symbolName)
                .scaledFont(16, relativeTo: .headline, weight: .semibold).foregroundStyle(.white)
                .frame(width: 36, height: 36)
                // Same dark frosted Liquid Glass as the hero's photo-context chrome — this
                // chip floats on artwork too (it was the app's one `.ultraThinMaterial` chip).
                .glassEffect(.regular.tint(Color.heroGlass), in: .rect(cornerRadius: 10, style: .continuous))
                .environment(\.colorScheme, .dark)
                .padding(Space.s14)
        }
        // Pin the card to the banner aspect so a library with no Primary image keeps full
        // height (and a tappable contentShape) instead of collapsing.
        .aspectRatio(JellyfinImage.landscape, contentMode: .fit)
        .clipShape(.rect(cornerRadius: Radius.card))
        .contentShape(.rect(cornerRadius: Radius.card))
        // tvOS system highlight masked to the banner's corners — pairs with the
        // `.borderless` style on the enclosing NavigationLink (`tvPosterButton`).
        .tvPosterHighlight(cornerRadius: Radius.card)
        .shadow(color: .black.opacity(0.2), radius: 8, y: 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(collection.name)
    }
}
