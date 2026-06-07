import SwiftUI

extension View {
    /// Poster/card focus on tvOS — no-op on iOS.
    @ViewBuilder
    func tvPosterButton() -> some View {
        #if os(tvOS)
        self.buttonStyle(.card)
        #else
        self
        #endif
    }

    /// Horizontal shelf item focus on tvOS.
    @ViewBuilder
    func tvShelfItem() -> some View {
        #if os(tvOS)
        self.buttonStyle(.card)
        #else
        self
        #endif
    }

    /// Genre/sort chip focus on tvOS.
    @ViewBuilder
    func tvChipButton() -> some View {
        #if os(tvOS)
        self.buttonStyle(.card)
        #else
        self
        #endif
    }

    /// Apply `modifier` only on iOS/iPadOS (e.g. backgroundExtensionEffect).
    @ViewBuilder
    func tvPlatformGated<Modified: View>(
        @ViewBuilder whenIOS: (Self) -> Modified
    ) -> some View {
        #if os(tvOS)
        self
        #else
        whenIOS(self)
        #endif
    }
}