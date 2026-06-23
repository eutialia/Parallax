import SwiftUI

/// The app's brand icon tile: the installed app-icon artwork (or an SF Symbol) on a rounded plate.
/// Extracted from `BrandMark` so the persistent tvOS settings rail can pin a large icon-ONLY mark
/// (no wordmark) while `BrandMark` keeps the icon-over-"Parallax" lockup the iOS surfaces use.
struct BrandTile: View, Equatable {
    /// The tile's contents: the real app icon (sign-in / settings) or a symbol glyph.
    enum Glyph: Equatable {
        /// The app's icon artwork (`BrandIcon` asset — light = Paper, dark = Graphite), clipped to
        /// the rounded tile so the mark reads as the installed app icon.
        case brandIcon
        /// An SF Symbol on the solid `label` tile.
        case symbol(String)
    }

    let glyph: Glyph
    /// The tile's side length.
    var size: CGFloat = 64
    /// The ambient color scheme, passed IN as a value (NOT read from `@Environment` here) so it's part
    /// of the identity `.equatable()` compares. The `brandIcon` variant is chosen by INVERTING this; if
    /// it were a hidden `@Environment` read, the `.equatable()` short-circuit below would skip the body
    /// on an appearance flip and freeze the icon on the stale variant. Callers pass their own
    /// `@Environment(\.colorScheme)`, so they (not the equatable-gated tile) re-render on the change.
    var colorScheme: ColorScheme

    private var cornerRadius: CGFloat { size * 0.225 }

    // Equatable on the VALUE inputs (glyph, size, colorScheme — everything the body reads): the tile is
    // identical across every focus move AND every settings nav push on the same screen, so `.equatable()`
    // lets SwiftUI skip re-rendering it. Otherwise a tvOS focus/transition recompute tears down and
    // re-decodes the multi-variant `BrandIcon` asset — a one-frame blank that reads as the icon
    // "flashing". `colorScheme` IS compared, so a real appearance change still re-renders (focus moves
    // don't change it, so the flash fix holds).
    static func == (lhs: BrandTile, rhs: BrandTile) -> Bool {
        lhs.glyph == rhs.glyph && lhs.size == rhs.size && lhs.colorScheme == rhs.colorScheme
    }

    var body: some View {
        tile
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            // A hairline border crisps the tile edge — the same edge the Home Screen draws around
            // installed icons — on top of the contrasting ground the `tile` itself resolves.
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.glassBorder, lineWidth: 1)
            )
            // No decorative shadow: depth in Parallax is glass + scrim, never shadow stacking off
            // media (DESIGN.md). The hairline border + the colorScheme-inverted icon ground already
            // separate the plate from the flat floor.
    }

    @ViewBuilder
    private var tile: some View {
        switch glyph {
        case .brandIcon:
            Image("BrandIcon")
                .resizable()
                .aspectRatio(contentMode: .fill)
                // Match the current appearance so the tile shows the SAME variant as the installed app
                // icon — Paper by day, Graphite by night — rather than inverting (which read as the
                // wrong icon for the mode). The dark Graphite ground does sit close to `Color.background`,
                // so the hairline border below carries the tile edge in dark mode.
                .environment(\.colorScheme, colorScheme)
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

/// The app's brand mark: the rounded `BrandTile` over the large "Parallax" title. Shared identity for
/// the iOS settings/connect surfaces (brand-on-top). tvOS no longer uses this — it pins an icon-only
/// `BrandTile` rail (`TVSettingsRail`) so the icon stays put across nav pushes while the wordmark is
/// dropped for a bigger glyph.
struct BrandMark: View {
    let glyph: BrandTile.Glyph
    let title: String
    /// The icon tile's side length.
    var tileSize: CGFloat = 64
    /// The "Parallax" title point size.
    var titleSize: CGFloat = 30

    /// Read here (not inside the equatable `BrandTile`) and forwarded down, so an appearance flip
    /// re-renders this mark and hands the tile a fresh `colorScheme` value.
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: tileSize * 0.19) {
            BrandTile(glyph: glyph, size: tileSize, colorScheme: colorScheme)
                .equatable()
            Text(title)
                // tvOS tames the 10-foot inflation (the iOS `.title`-scale mark balloons against
                // the screen); iOS keeps the Dynamic-Type-scaled display size.
                #if os(tvOS)
                .font(.system(size: titleSize, weight: .bold))
                #else
                .scaledFont(titleSize, relativeTo: .title, weight: .bold)
                #endif
                .foregroundStyle(Color.label)
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
