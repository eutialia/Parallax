import SwiftUI

/// Icon-only circular glass action button used over the hero backdrop (Favorite,
/// Watched, …) — the design's `gbtn`. White glyph + fixed dark frosted glass so the
/// control stays legible on bright photography and does not flip with the app's
/// light/dark setting (same approach as the player chrome: tinted glass + pinned
/// `.dark` for material resolution). The explicit `contentShape(Circle())` is
/// load-bearing: `.glassEffect` adds no hit fill, so without it only the rendered glyph
/// would be tappable.
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
                .glassEffect(.regular.tint(Color.heroGlass), in: Circle())
                .overlay(Circle().strokeBorder(Color.heroGlassBorder, lineWidth: 1))
                .shadow(color: .black.opacity(0.32), radius: 8, y: 4)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        // Bare `.glassEffect(.regular)` follows `colorScheme`; pin dark so Matinee
        // doesn't resolve the light frosted variant over hero photography.
        .environment(\.colorScheme, .dark)
        .accessibilityLabel(Text(accessibilityLabel))
    }
}

#Preview("CircleGlassButton · bright artwork") {
    ZStack {
        LinearGradient(
            colors: [Color(red: 0.95, green: 0.92, blue: 0.85),
                     Color(red: 0.78, green: 0.82, blue: 0.90)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()
        HStack(spacing: Space.s12) {
            CircleGlassButton(systemImage: "heart", accessibilityLabel: "Favorite") {}
            CircleGlassButton(systemImage: "heart.fill", isActive: true, accessibilityLabel: "Favorite") {}
        }
    }
    .preferredColorScheme(.light)
}
