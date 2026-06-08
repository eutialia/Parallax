import SwiftUI

// tvOS layout helpers for full-bleed hero screens. tvOS reserves a title-safe / overscan inset
// on all four edges and the system applies it as the safe area, so by default ALL content —
// including full-bleed hero artwork — is pushed in from the physical screen edge. These two
// helpers form a pair: `heroScreenSafeArea()` drops the horizontal inset on the scroll
// container so the artwork can reach the edges, and `tvContentInset()` re-adds it to the
// non-hero content so focusable shelves/body stay inside the title-safe region.
// (Apple HIG "Designing for tvOS"; WWDC19 "Mastering the Living Room With tvOS".)

extension View {
    /// Hero screens: let full-bleed artwork reach the screen edges. iOS only drops the TOP inset
    /// (the hero bleeds under the status bar); tvOS also drops the HORIZONTAL overscan inset so
    /// the artwork spans the full width. Pair every use with `tvContentInset()` on the non-hero
    /// content so it doesn't bleed into overscan too.
    @ViewBuilder
    func heroScreenSafeArea() -> some View {
        #if os(tvOS)
        self.ignoresSafeArea(edges: [.top, .horizontal])
        #else
        self.ignoresSafeArea(edges: .top)
        #endif
    }

    /// Re-add the tvOS title-safe horizontal inset that `heroScreenSafeArea()` dropped, so
    /// focusable shelves/body stay inside the overscan-safe region instead of being clipped at
    /// the physical edge. Applied via `safeAreaPadding` (not `padding`) so nested horizontal
    /// shelves inset their scroll content exactly like the system safe area used to. No-op on
    /// iOS, where the horizontal safe area was never dropped.
    @ViewBuilder
    func tvContentInset() -> some View {
        #if os(tvOS)
        self.safeAreaPadding(.horizontal, AppLayout.tvOverscanInset)
        #else
        self
        #endif
    }
}
