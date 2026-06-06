import SwiftUI

extension View {
    /// Matinee / dark floor that fills tab *content* behind scrollable screens.
    /// Applied inside each tab's `NavigationStack` (not on `TabView` itself) so
    /// sidebar / tab-bar chrome keeps system glass while content shows `Color.background`.
    func appScreenBackground() -> some View {
        frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.background)
    }
}