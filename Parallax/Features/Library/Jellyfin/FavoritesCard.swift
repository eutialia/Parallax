import SwiftUI

/// Navigation value for the Favorites drill-down — it has no `MediaCollection`
/// to ride on (it's a virtual, cross-library grid).
struct FavoritesRoute: Hashable {}

/// The Favorites entry in the Library list. Server libraries get a 16:9 banner
/// with the name baked into the art; Favorites has no server art, so this card
/// paints its own quiet field — the shared frosted glyph chip for type, the name
/// set in text where the banner art would carry it, and an oversized heart
/// watermark so the tile doesn't read as a loading placeholder.
struct FavoritesCard: View {
    var body: some View {
        ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(Color.fill)
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: "heart.fill")
                        .font(.system(size: 110))
                        .foregroundStyle(Color.label.opacity(0.07))
                        .rotationEffect(.degrees(-10))
                        .offset(x: 16, y: 22)
                }
            // Mirror LibraryCard's chip exactly (size, glass, inset) so the grid
            // scans as one family.
            Image(systemName: "heart")
                .scaledFont(16, relativeTo: .headline, weight: .semibold).foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .glassEffect(.regular.tint(Color.heroGlass), in: .rect(cornerRadius: 10, style: .continuous))
                .environment(\.colorScheme, .dark)
                .padding(Space.s14)
            Text("Favorites")
                .scaledFont(22, relativeTo: .title3, weight: .bold)
                .foregroundStyle(Color.label)
                .padding(Space.s14)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        }
        .aspectRatio(JellyfinImage.landscape, contentMode: .fit)
        .clipShape(.rect(cornerRadius: Radius.card))
        .contentShape(.rect(cornerRadius: Radius.card))
        .tvPosterHighlight(cornerRadius: Radius.card)
        .shadow(color: .black.opacity(0.2), radius: 8, y: 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Favorites")
    }
}

#Preview("Favorites card", traits: .sizeThatFitsLayout) {
    FavoritesCard()
        .frame(width: 360)
        .padding()
        .background(Color.background)
}
