import SwiftUI

/// Circular account glyph — the user's first initial on the fill tint. Shared by the
/// sidebar footer, the compact nav-bar account button, and the settings header so the
/// avatar reads identically everywhere. The glyph scales with the circle so it stays
/// centered and uncramped at every call size.
struct AccountAvatar: View {
    let name: String
    var size: CGFloat = 34

    var body: some View {
        Circle()
            .fill(Color.fill)
            .frame(width: size, height: size)
            .overlay {
                Text(initial)
                    // Fixed-size (not Dynamic Type) so the initial always fits the circle.
                    .font(.system(size: size * 0.44, weight: .semibold))
                    .foregroundStyle(Color.label)
            }
    }

    private var initial: String {
        guard let first = name.first else { return "?" }
        return String(first).uppercased()
    }
}
