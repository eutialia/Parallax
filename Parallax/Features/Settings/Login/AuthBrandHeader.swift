import SwiftUI

/// The persistent brand mark for the auth screens: a 64pt rounded tile (the app icon, or an SF
/// Symbol) over the large "Parallax" title. The per-screen subtitle that used to sit under it now
/// lives in each screen's body, so the mark can stay put while the bodies slide — the logged-out
/// source picker renders this once and slides the picker rows / sign-in form beneath it.
struct AuthBrandMark: View {
    /// The 64pt tile's contents: the real app icon (sign-in) or a symbol glyph (secondary screens).
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
    AuthBrandMark(glyph: .brandIcon, title: "Parallax")
        .padding(60)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.background)
        .preferredColorScheme(.dark)
}
#endif

/// Centered, secondary subtitle that sits under the brand mark in each auth body. Pulled out of the
/// old combined header so it travels with the sliding body while `AuthBrandMark` stays put.
struct AuthSubtitle: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.authSubtitle)
            .foregroundStyle(Color.secondaryLabel)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
    }
}
