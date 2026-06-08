import SwiftUI

extension View {
    /// Poster/artwork button style. On tvOS a custom uniform-lift style (`TVPosterButtonStyle`):
    /// it scales + drop-shadows the WHOLE clipped tile on focus, so the entire card grows and
    /// elevates as one piece. We deliberately do NOT use `.card`/`.borderless`: `.borderless`
    /// applies the system's image-ONLY focus motion (the inner art tilts/zooms while the
    /// container never lifts) and masks that highlight to a system corner radius that mismatches
    /// our `Radius.tile`/`Radius.card`, leaving dark corners poking out past the rounded art.
    /// `.card` drew a light platter that bled past the corners as a white halo. The custom style
    /// introduces no second shape — it scales the already-clipped tile, so its own corners stay
    /// intact. `.plain` on iOS. OWNS the button style — do NOT pair it with a separate
    /// `.buttonStyle(.plain)` at the call site: a nearer (inner) style wins and kills the focus
    /// effect, leaving the tile focus-dead on Apple TV. One style, set here, per control.
    @ViewBuilder
    func tvPosterButton() -> some View {
        #if os(tvOS)
        self.buttonStyle(TVPosterButtonStyle())
        #else
        self.buttonStyle(.plain)
        #endif
    }

    /// Horizontal shelf-item button style: the same custom uniform-lift `TVPosterButtonStyle` as
    /// `tvPosterButton()` on tvOS (whole-tile scale + shadow, not the system image-only parallax),
    /// `.plain` on iOS. Owns the button style; don't pair an inner `.buttonStyle(.plain)` (it wins
    /// and kills tvOS focus).
    @ViewBuilder
    func tvShelfItem() -> some View {
        #if os(tvOS)
        self.buttonStyle(TVPosterButtonStyle())
        #else
        self.buttonStyle(.plain)
        #endif
    }

    /// Chip/transport button style for controls that carry their OWN chrome (glass capsule,
    /// glass circle). On tvOS a custom style that lifts via `tvFocusEffect()` — the same gentle
    /// scale+brightness+shadow `CircleGlassButton`/`PrimaryPlayButton` use — instead of the
    /// system `.card` platter, which drew a bright rounded box around the control and read as a
    /// "super white" focus highlight that overlapped neighbours. `.plain` on iOS. Owns the
    /// button style — see `tvPosterButton()` for why a paired inner `.buttonStyle(.plain)` must
    /// not be added.
    @ViewBuilder
    func tvChipButton() -> some View {
        #if os(tvOS)
        self.buttonStyle(TVGlassChipButtonStyle())
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
/// Chip/transport button style: lifts the label with `tvFocusEffect()` (gentle
/// scale+brightness+shadow) and dims slightly on press — no system `.card` platter. Applying
/// `tvFocusEffect()` to `configuration.label` works because the label is a descendant of the
/// focusable Button, so its `@Environment(\.isFocused)` reports the Button's focus (the same
/// reason `PrimaryPlayButtonStyle` can lift this way).
struct TVGlassChipButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .tvFocusEffect()
    }
}

/// Poster/artwork button style: scales + drop-shadows the WHOLE clipped tile on focus — a
/// uniform Apple-TV "pop" where the entire card grows and lifts as one. Reads the focusable
/// Button's focus through the same `@Environment(\.isFocused)` path as the chip style. There's
/// no system platter or image-only parallax, so the already-rounded tile scales as a single unit
/// with its own `Radius.tile`/`Radius.card` corners intact — no second shape, no dark-corner
/// mismatch. Dims slightly on press for Select feedback.
struct TVPosterButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.9 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .modifier(TVFocusEffect(
                scale: 1.1,
                brightness: 0,
                shadowRadius: 22,
                shadowY: 16,
                animation: .spring(response: 0.34, dampingFraction: 0.72)
            ))
    }
}

/// Reads the enclosing Button's focus and applies a uniform lift (scale + drop shadow, optional
/// brightness). It lives on the button's label (a descendant of the focusable Button), so
/// `isFocused` reports the Button's state — `ButtonStyleConfiguration` exposes only `isPressed`,
/// never focus, which is why a press-only custom style appears dead as focus moves across it on
/// Apple TV. Defaults are the gentle chip lift; posters pass a larger scale + shadow + spring.
private struct TVFocusEffect: ViewModifier {
    var scale: CGFloat = 1.06
    var brightness: Double = 0.06
    var shadowRadius: CGFloat = 18
    var shadowY: CGFloat = 12
    var animation: Animation = .easeOut(duration: 0.18)

    @Environment(\.isFocused) private var isFocused

    func body(content: Content) -> some View {
        content
            .scaleEffect(isFocused ? scale : 1)
            .brightness(isFocused ? brightness : 0)
            .shadow(
                color: .black.opacity(isFocused ? 0.4 : 0),
                radius: isFocused ? shadowRadius : 0,
                y: isFocused ? shadowY : 0
            )
            .animation(animation, value: isFocused)
    }
}
#endif
