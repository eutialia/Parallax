import SwiftUI

/// The app's brand mark: a 64pt rounded tile (the app icon, or an SF Symbol) over the large
/// "Parallax" title. Shared identity — it heads the logged-out source picker and now the Settings
/// root, so it lives in the shared layer rather than the login folder (no longer auth-exclusive).
/// The per-screen subtitle that used to sit under it lives in each screen's body (`AuthSubtitle`),
/// so the mark can stay put while bodies slide.
struct BrandMark: View {
    /// The 64pt tile's contents: the real app icon (sign-in / settings) or a symbol glyph.
    enum Glyph {
        /// The app's icon artwork (`BrandIcon` asset — light = Paper, dark = Graphite), clipped to
        /// the rounded tile so the mark reads as the installed app icon.
        case brandIcon
        /// An SF Symbol on the solid `label` tile.
        case symbol(String)
    }

    let glyph: Glyph
    let title: String

    var body: some View {
        VStack(spacing: Space.s12) {
            tile
                .frame(width: 64, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
                // The Graphite (dark) icon's own fill matches `Color.background`, so on a dark floor
                // the tile edge vanishes and only the logo's rings show ("two circles floating").
                // A hairline border gives the tile a defined edge so it reads as a contained app
                // icon — the same edge the Home Screen draws around installed icons.
                .overlay(
                    RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                        .strokeBorder(Color.glassBorder, lineWidth: 1)
                )
            Text(title)
                // tvOS tames the 10-foot inflation (the iOS `.title`-scale mark balloons against
                // the screen); iOS keeps the Dynamic-Type-scaled display size.
                #if os(tvOS)
                .font(.system(size: 30, weight: .bold))
                #else
                .scaledFont(30, relativeTo: .title, weight: .bold)
                #endif
                .foregroundStyle(Color.label)
        }
    }

    @ViewBuilder
    private var tile: some View {
        switch glyph {
        case .brandIcon:
            Image("BrandIcon")
                .resizable()
                .aspectRatio(contentMode: .fill)
        case .symbol(let name):
            // The outer `.clipShape` rounds this fill, so the tile draws a flat label color here
            // rather than re-stating the same rounded rectangle.
            Color.label
                .overlay {
                    Image(systemName: name)
                        .scaledFont(30, relativeTo: .title, weight: .semibold)
                        .foregroundStyle(Color.background)
                }
        }
    }
}

#if DEBUG
/// Verifies the brand tile reads as a contained icon on a dark floor (the tvOS / dark-mode case):
/// the Graphite icon's own fill matches `Color.background`, so without the hairline border the tile
/// edge vanishes and only the logo rings show. Render in dark mode and confirm a defined tile edge.
#Preview("Brand mark · dark floor", traits: .sizeThatFitsLayout) {
    BrandMark(glyph: .brandIcon, title: "Parallax")
        .padding(60)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.background)
        .preferredColorScheme(.dark)
}
#endif
