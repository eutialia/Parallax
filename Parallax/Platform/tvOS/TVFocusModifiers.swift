import SwiftUI

extension View {
    /// Poster/card button style: `.card` (system focus lift) on tvOS, `.plain` on iOS.
    /// This OWNS the button style for the control — do NOT pair it with a separate
    /// `.buttonStyle(.plain)` at the call site. A nearer (inner) `.buttonStyle` wins over a
    /// farther one, so an inner `.plain` would silently defeat `.card` and leave the card
    /// focus-dead on Apple TV. One style, set here, per control.
    @ViewBuilder
    func tvPosterButton() -> some View {
        #if os(tvOS)
        self.buttonStyle(.card)
        #else
        self.buttonStyle(.plain)
        #endif
    }

    /// Horizontal shelf-item button style: `.card` on tvOS, `.plain` on iOS. Owns the button
    /// style — see `tvPosterButton()` for why a paired inner `.buttonStyle(.plain)` must not be
    /// added (it wins over `.card` and kills tvOS focus).
    @ViewBuilder
    func tvShelfItem() -> some View {
        #if os(tvOS)
        self.buttonStyle(.card)
        #else
        self.buttonStyle(.plain)
        #endif
    }

    /// Chip/transport button style: `.card` on tvOS, `.plain` on iOS. Owns the button style —
    /// see `tvPosterButton()` for why a paired inner `.buttonStyle(.plain)` must not be added.
    @ViewBuilder
    func tvChipButton() -> some View {
        #if os(tvOS)
        self.buttonStyle(.card)
        #else
        self.buttonStyle(.plain)
        #endif
    }

    /// Group a row/section so the tvOS focus engine treats it as one unit (preferred focus
    /// target, contained traversal). No-op on iOS.
    @ViewBuilder
    func tvFocusSection() -> some View {
        #if os(tvOS)
        self.focusSection()
        #else
        self
        #endif
    }

    /// tvOS focus affordance for action controls that use a custom or `.plain` ButtonStyle —
    /// those carry NO system focus effect, so the focus engine lands on them invisibly. Apply to
    /// a Button's LABEL (a descendant of the focusable Button) so it reads the Button's focus via
    /// `@Environment(\.isFocused)` and lifts + scales like the system focus engine does for
    /// `.card`/`.borderedProminent`. No-op on iOS, where focus doesn't exist.
    @ViewBuilder
    func tvFocusEffect() -> some View {
        #if os(tvOS)
        modifier(TVFocusEffect())
        #else
        self
        #endif
    }

    /// Apply `whenIOS` only on iOS/iPadOS (e.g. `backgroundExtensionEffect`, which tvOS lacks).
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

#if os(tvOS)
/// Reads the enclosing Button's focus and applies the standard tvOS lift + scale. It lives on
/// the button's label (a descendant of the focusable Button), so `isFocused` reports the
/// Button's state — `ButtonStyleConfiguration` exposes only `isPressed`, never focus, which is
/// why a press-only custom style appears dead as focus moves across it on Apple TV.
private struct TVFocusEffect: ViewModifier {
    @Environment(\.isFocused) private var isFocused

    func body(content: Content) -> some View {
        content
            .scaleEffect(isFocused ? 1.06 : 1)
            .brightness(isFocused ? 0.06 : 0)
            .shadow(
                color: .black.opacity(isFocused ? 0.4 : 0),
                radius: isFocused ? 18 : 0,
                y: isFocused ? 12 : 0
            )
            .animation(.easeOut(duration: 0.18), value: isFocused)
    }
}
#endif
