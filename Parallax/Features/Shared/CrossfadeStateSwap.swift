import SwiftUI

extension View {
    /// Crossfades a screen's loading→loaded/failed/empty content swap — Home, Library, and the
    /// two detail screens all replace their entire content subtree on a view-model state change
    /// with no `.transition`, a hard cut. Attach once to the STABLE container wrapping that
    /// `switch`/`if` chain, keyed on a small `Hashable` "phase" that discriminates only which
    /// branch is showing — never the raw view-model state enum directly (those usually carry
    /// payloads, e.g. `.failed(message)`, so they aren't `Hashable`).
    ///
    /// Flips `.id(phase)` on the wrapped content so the swap is a REAL insert/remove: a
    /// `.transition` attached to an otherwise-stable wrapper never fires, because nothing about
    /// that wrapper's own identity changed — only forcing a fresh `.id` guarantees SwiftUI tears
    /// the old subtree down and animates a new one in (same recipe as `LoginView`'s
    /// `.id(vm.mode)`).
    ///
    /// iOS/iPadOS only: `.easeOut(duration: 0.25)`, pure opacity — kept even under Reduce
    /// Motion (precedent `LoginView.swift:99`), since there's no position/scale to gentle down,
    /// unlike `staleWhileRevalidate`'s dim, which Reduce Motion drops entirely.
    ///
    /// tvOS keeps the pre-existing hard cut, skipping the `.id`/`.transition`/`.animation`
    /// entirely rather than merely nil-ing the animation: re-identifying focusable content mid-
    /// animation re-evaluates the focus engine and parks focus wrong (see `StaleWhileRevalidate`
    /// and `HomeHeroCarousel.swift:93-105`).
    func crossfadeStateSwap<Phase: Hashable>(_ phase: Phase) -> some View {
        modifier(CrossfadeStateSwap(phase: phase))
    }
}

private struct CrossfadeStateSwap<Phase: Hashable>: ViewModifier {
    let phase: Phase

    func body(content: Content) -> some View {
        #if os(tvOS)
        content
        #else
        content
            .id(phase)
            .transition(.opacity)
            .animation(.contentSwap, value: phase)
        #endif
    }
}
