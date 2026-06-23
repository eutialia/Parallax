import SwiftUI

/// Navigation value for the Favorites drill-down — it has no `MediaCollection`
/// to ride on (it's a virtual, cross-library grid).
struct FavoritesRoute: Hashable {}

/// The Favorites entry in the Library list — the Favorites flavor of the shared `LibraryBannerCard`.
/// Server libraries get a 16:9 banner with the name baked into the art; Favorites has no server art, so
/// it paints the same neutral self-field as the SMB card: the shared frosted glyph chip (a heart), the
/// name in text, and an oversized heart watermark so the tile doesn't read as a loading placeholder.
/// Kept as a named view for the call site; the chrome lives in `LibraryBannerCard` so the three flavors
/// can't drift apart.
struct FavoritesCard: View {
    var body: some View {
        LibraryBannerCard(
            chipGlyph: "heart",
            displayName: "Favorites",
            accessibilityName: "Favorites",
            watermark: ("heart.fill", 110)
        ) {
            Rectangle().fill(Color.fill)
        }
    }
}

#Preview("Favorites card", traits: .sizeThatFitsLayout) {
    FavoritesCard()
        .frame(width: 360)
        .padding()
        .background(Color.background)
}
