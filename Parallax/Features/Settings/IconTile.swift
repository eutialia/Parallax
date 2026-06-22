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
            Image(image)
                .resizable()
                .scaledToFit()
                .frame(width: glyphSize, height: glyphSize)
                .foregroundStyle(foreground)
        } else if let systemImage {
            Image(systemName: systemImage)
                .font(.system(size: glyphSize, weight: glyphWeight))
                .foregroundStyle(foreground)
        }
    }
}
