import SwiftUI

/// Icon-only circular glass action button used over the hero backdrop (Favorite,
/// Watched, …) — the design's `gbtn`. Content reads white against the backdrop scrim in
/// both themes (artwork stays the only colour; chrome is monochrome). The explicit
/// `contentShape(Circle())` is load-bearing: `.glassEffect` adds no hit fill, so without
/// it only the rendered glyph would be tappable.
struct CircleGlassButton: View {
    let systemImage: String
    var isActive: Bool = false
    let accessibilityLabel: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .scaledFont(18, relativeTo: .headline, weight: .semibold)
                .foregroundStyle(.white.opacity(isActive ? 1 : 0.9))
                .frame(width: 46, height: 46)
                .glassEffect(.regular, in: Circle())
                .overlay(Circle().strokeBorder(.white.opacity(0.22), lineWidth: 1))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(accessibilityLabel))
    }
}
