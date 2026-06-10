import SwiftUI

/// Heart control over hero/detail backdrops — wraps `CircleGlassButton` so every screen
/// shares the same iconography and accessibility label.
struct FavoriteActionButton: View {
    let isFavorite: Bool
    let action: () -> Void

    var body: some View {
        CircleGlassButton(
            systemImage: isFavorite ? "heart.fill" : "heart",
            // Stateful so VoiceOver announces what the tap will DO, not just the control's name.
            accessibilityLabel: isFavorite ? "Remove from Favorites" : "Add to Favorites",
            action: action
        )
    }
}