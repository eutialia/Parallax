import SwiftUI

extension View {
    /// The stale-while-revalidate transition shared by the library grid and the Home
    /// shelves: while a background re-fetch is in flight, dim the *outgoing* content and
    /// suspend its hit-testing, then crossfade the fresh data back in when it clears —
    /// so the swap reads as one soft dissolve instead of a skeleton flash.
    ///
    /// tvOS swaps INSTANTLY (no animation): a crossfade replacing focusable content makes
    /// the focus engine re-evaluate for the whole animation window, parking focus off the
    /// header controls until it settles. iOS has no focus to lose, so it keeps the
    /// crossfade. Reduce Motion drops both the dim and the animation.
    func staleWhileRevalidate(isRefreshing: Bool, reduceMotion: Bool) -> some View {
        modifier(StaleWhileRevalidate(isRefreshing: isRefreshing, reduceMotion: reduceMotion))
    }
}

private struct StaleWhileRevalidate: ViewModifier {
    let isRefreshing: Bool
    let reduceMotion: Bool

    func body(content: Content) -> some View {
        content
            .opacity(isRefreshing && !reduceMotion ? 0.45 : 1)
            .allowsHitTesting(!isRefreshing)
            // Keyed on `isRefreshing` — the only input the opacity derives from — so the
            // crossfade runs in BOTH directions (dim down, brighten back).
            .animation(animation, value: isRefreshing)
    }

    private var animation: Animation? {
        if reduceMotion { return nil }
        #if os(tvOS)
        return nil
        #else
        return .smooth
        #endif
    }
}
