import SwiftUI

extension View {
    /// Matinee / dark floor that fills the content area behind scrollable screens.
    /// Applied to the root of a `NavigationStack` tab (or a pushed destination) so
    /// transparent `ScrollView`s show `Color.background` instead of system white.
    func appScreenBackground() -> some View {
        frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.background)
    }
}