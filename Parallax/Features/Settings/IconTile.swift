import SwiftUI

/// A rounded-square icon chip: a filled tile with a centered, fixed-size glyph — an SF Symbol
/// (`systemImage`) or a template asset (`image`, e.g. the Jellyfin mark). The glyph size is fixed
/// (not Dynamic-Type-scaled) so it can't overflow the fixed tile — surrounding labels still scale.
/// Shared by the settings rows, the server cards, and the per-server settings header.
struct IconTile: View {
    var systemImage: String? = nil
    /// A template image asset for the glyph, used in place of an SF Symbol when set (tinted like the
    /// symbol, so a monochrome template is expected — e.g. `JellyfinGlyph`).
    var image: String? = nil
    var size: CGFloat
    var cornerRadius: CGFloat
    var glyphSize: CGFloat
    var glyphWeight: Font.Weight = .semibold
    var fill: Color = Color.fill
    var foreground: Color = Color.label

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(fill)
            .frame(width: size, height: size)
            .overlay { glyph }
    }

    @ViewBuilder
    private var glyph: some View {
        if let image {
            TemplateGlyph(name: image, size: glyphSize)
                .foregroundStyle(foreground)
        } else if let systemImage {
            Image(systemName: systemImage)
                .font(.system(size: glyphSize, weight: glyphWeight))
                .foregroundStyle(foreground)
        }
    }
}

/// A template image asset (e.g. `JellyfinGlyph`) drawn so it optically matches an SF Symbol of the same
/// nominal point `size`. A light/sparse mark reads smaller than a solid, often-wide symbol at equal point
/// size, so it renders at `size × opticalScale`. This is the ONE place that knows the template-vs-symbol
/// size relationship — callers pass the symbol size they'd use and apply their own `.foregroundStyle`
/// tint. Render-tuned against `externaldrive.badge.wifi` (geometric-mean match; see the `Source row
/// glyphs` preview). Used by `IconTile`, `SettingsRowLabel`, `ServerIdentityHero`, and `BrandTile`.
struct TemplateGlyph: View {
    let name: String
    let size: CGFloat
    /// Light template marks read ~10% smaller than solid/wide SF Symbols at equal point size.
    static let opticalScale: CGFloat = 1.1

    var body: some View {
        let s = size * Self.opticalScale
        Image(name).resizable().scaledToFit().frame(width: s, height: s)
    }
}

#if DEBUG
/// Source-glyph optical-match guard (end-to-end, through `TemplateGlyph`): the Jellyfin row (template
/// `image`) above the SMB row (`externaldrive.badge.wifi` symbol), both at `iconSize: 22`. The Jellyfin
/// mark is a light outline triangle, so it must read the SAME size as the wide solid drive by EYE —
/// `TemplateGlyph` renders the `image` ~1.1× the symbol size to achieve that. If the scale or the asset
/// drifts, the two leading glyphs visibly mismatch here.
#Preview("Source row glyphs ·", traits: .fixedLayout(width: 560, height: 220)) {
    VStack(spacing: 0) {
        SettingsListRow(image: "JellyfinGlyph", iconSize: 22, title: "Jellyfin Server",
                        subtitle: "Sign in to your media server", accessory: .chevron)
        SettingsListRow(systemImage: "externaldrive.badge.wifi", iconSize: 22, title: "Network Share",
                        subtitle: "Connect over SMB to a shared folder", accessory: .chevron)
    }
    .padding(20)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .screenFloor()
    .preferredColorScheme(.dark)
}
#endif
