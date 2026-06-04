import SwiftUI

/// A rounded-square icon chip: a filled tile with a centered, fixed-size SF Symbol.
/// The glyph size is fixed (not Dynamic-Type-scaled) so it can't overflow the fixed
/// tile — surrounding labels still scale. Shared by the settings rows, the server
/// cards, and the per-server settings header.
struct IconTile: View {
    let systemImage: String
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
            .overlay {
                Image(systemName: systemImage)
                    .font(.system(size: glyphSize, weight: glyphWeight))
                    .foregroundStyle(foreground)
            }
    }
}
