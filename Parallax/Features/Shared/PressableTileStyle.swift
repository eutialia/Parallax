import SwiftUI

/// iOS/iPadOS touch-down feedback for full-bleed artwork tiles: a subtle press-in scale so a tap is
/// acknowledged the instant a finger lands, *before* the `.zoom` detail push fires on release. The
/// default `.plain` style only "may apply a visual effect to indicate the pressed state" — on these
/// posters that amounts to a faint opacity dim that barely reads over artwork, so this adds the
/// motion cue the Photos / Apple TV tiles use. Purely presentational: the enclosing `Button` /
/// `NavigationLink` owns the action and the zoom source.
///
/// iOS-only by construction — apply it through `pressableTileButton()`, which keeps tvOS on its
/// native `.borderless` focus lockup (`tvPosterButton()`) and never reaches this style.
struct PressableTileStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Exact motion spec: a 3% press-in, released on the same easeOut both ways (symmetric at this
    /// scale). `.center` anchor (scaleEffect default) keeps the shrink concentric, so the tile — and
    /// the `matchedTransitionSource` frame it hosts — stays put; only a symmetric inset animates, and
    /// it has unwound to identity by the time release triggers the zoom push.
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(pressedScale(configuration.isPressed))
            .opacity(pressedOpacity(configuration.isPressed))
            .animation(.tilePressResponse, value: configuration.isPressed)
    }

    /// Reduce Motion pins the scale — the grow/shrink is the movement WCAG 2.3.3 targets — mirroring
    /// the `TVFocusEffect` precedent that drops its focus lift under RM.
    private func pressedScale(_ pressed: Bool) -> CGFloat {
        pressed && !reduceMotion ? 0.97 : 1
    }

    /// With motion, scale is the whole cue (opacity stays 1). Under RM, where scale is pinned, a gentle
    /// dim is the non-motion substitute so the tap still acknowledges — a pure-opacity fade, the RM
    /// convention in this codebase.
    private func pressedOpacity(_ pressed: Bool) -> Double {
        pressed && reduceMotion ? 0.85 : 1
    }
}
