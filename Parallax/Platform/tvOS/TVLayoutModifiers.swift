import SwiftUI

// tvOS layout helpers for full-bleed hero screens. tvOS reserves a title-safe / overscan inset
// on all four edges and the system applies it as the safe area, so by default ALL content —
// including full-bleed hero artwork — is pushed in from the physical screen edge. These two
// helpers form a pair: `heroScreenSafeArea()` drops the horizontal inset on the scroll
// container so the artwork can reach the edges, and `tvContentInset()` re-adds it to the
// non-hero content so focusable shelves/body stay inside the title-safe region.
// (Apple HIG "Designing for tvOS"; WWDC19 "Mastering the Living Room With tvOS".)

extension EnvironmentValues {
    /// True PHYSICAL window height (overscan included), measured ONCE at the app root by
    /// `measuresHeroViewport()` and read by `HeroBandFrame` so a full-bleed tvOS hero fills the WHOLE
    /// screen. It MUST be measured at the root, not per-screen: a screen inside the `.sidebarAdaptable`
    /// TabView (Home) caps at the tab content region — an overscan strip short of the window — so a
    /// `containerRelativeFrame`/local reader there lands ~90pt low and peeks the next row (a full-screen
    /// navigation push like the detail header measures the whole window and doesn't). 0 = unset (iOS,
    /// or the first frame before measurement) → the band falls back to the fraction.
    @Entry var heroViewportHeight: CGFloat = 0
}

extension View {
    /// Hero screens: let full-bleed artwork reach the screen edges. iOS only drops the TOP inset
    /// (the hero bleeds under the status bar); tvOS also drops the HORIZONTAL overscan inset so
    /// the artwork spans the full width. Pair every use with `tvContentInset()` on the non-hero
    /// content so it doesn't bleed into overscan too. The full-screen HEIGHT comes from
    /// `\.heroViewportHeight` (published by `measuresHeroViewport()` at the app root), and the band's
    /// bottom paints into the overscan via the screen's own `scrollClipDisabled` — so no bottom safe
    /// area is dropped here and the shelves/body keep their natural title-safe bottom inset.
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

    /// Let a focused tile's lift/shadow paint past a horizontal scroll view's bounds instead of
    /// being clipped at the row/edge. tvOS only — there's no focus lift to spill on iOS.
    @ViewBuilder
    func tvScrollClipDisabled() -> some View {
        #if os(tvOS)
        self.scrollClipDisabled()
        #else
        self
        #endif
    }

    /// Apply ONCE at the app root (outside the TabView): measures the true physical window height —
    /// overscan included — into `\.heroViewportHeight` so every full-bleed tvOS hero can fill the
    /// whole screen. Must be the ROOT, not a hero screen: a screen inside the `.sidebarAdaptable`
    /// TabView (Home) only ever sees its tab content region, an overscan strip short of the window,
    /// so it would peek the next row (see `heroViewportHeight`). Uses `PlayerPresentationHost`'s
    /// `size + safeAreaInsets` formula. No-op on iOS, where the hero is aspect-ratio sized.
    @ViewBuilder
    func measuresHeroViewport() -> some View {
        #if os(tvOS)
        modifier(HeroViewportProbe())
        #else
        self
        #endif
    }
}

#if os(tvOS)
/// Root-level probe for the true window height — see `measuresHeroViewport()`. The background reader
/// (`.ignoresSafeArea()` so it spans the full window) measures the stable window size, writing state
/// only on a real size change, then publishes it down via `\.heroViewportHeight`.
private struct HeroViewportProbe: ViewModifier {
    @State private var height: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .environment(\.heroViewportHeight, height)
            .background {
                GeometryReader { geo in
                    Color.clear
                        .onAppear { measure(geo) }
                        .onChange(of: geo.size.height) { measure(geo) }
                }
                .ignoresSafeArea()
            }
    }

    private func measure(_ geo: GeometryProxy) {
        // `PlayerPresentationHost`'s "size + safe insets = true window" formula. On the tvOS root
        // the reader already `.ignoresSafeArea()`, so `size` is the full 1080-tall window and the
        // insets are ~0 — the `+ insets` is the proven formula's defensive tail (it does the real
        // work only where the reader is safe-area-bounded), NOT a double-count of the overscan.
        height = geo.size.height + geo.safeAreaInsets.top + geo.safeAreaInsets.bottom
    }
}
#endif
