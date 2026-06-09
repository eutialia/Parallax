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

    /// Raise a grid/stack cell above its siblings while the focusable it contains is focused.
    /// Our custom poster/chip styles lift via a pure render transform (`tvFocusEffect()` scales +
    /// shadows the tile) but never elevate the cell's `zIndex`, so a `LazyVGrid`/`LazyHStack`
    /// paints later siblings (the right neighbour and the row below) ON TOP of the lifted card —
    /// the focus pop reads as the neighbours overlapping it. The system `.card` style avoids this
    /// because the focus engine floats the focused cell; this restores the same behaviour for the
    /// custom style. Apply to the CELL (the `ForEach` element / grid child) — `zIndex` only
    /// reorders siblings of the layout container, so placing it inside the ButtonStyle can't lift
    /// the whole button above its grid neighbours. Reads the descendant focusable's focus via the
    /// `TVFocusElevationKey` preference that `tvFocusEffect()` publishes. No-op on iOS.
    @ViewBuilder
    func tvFocusElevated() -> some View {
        #if os(tvOS)
        modifier(TVFocusElevationModifier())
        #else
        self
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

/// Player scrubber style: renders the label with NO system focus chrome and no lift — `.plain`
/// on tvOS paints the system focus platter (a bright rounded box) around the whole label, which
/// swallowed the full-width progress bar. The bar communicates focus itself (`PlayerProgressBar`
/// `.focused` mode: handle grows + soft outline ring), so the style's only job is to suppress
/// the platter while keeping the Button focusable. Slight dim on press for Select feedback.
struct TVScrubberButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.9 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
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
            // Publish this focusable's focus so an enclosing `tvFocusElevated()` cell can raise its
            // `zIndex` and float the lifted tile above its grid siblings (see `tvFocusElevated()`).
            .preference(key: TVFocusElevationKey.self, value: isFocused)
    }
}

/// Carries a focusable's focus state up to an ancestor cell so it can elevate (`tvFocusElevated()`).
/// OR-reduced: a cell elevates if any focusable in its subtree is focused (each grid cell holds one).
private struct TVFocusElevationKey: PreferenceKey {
    static let defaultValue = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) {
        value = value || nextValue()
    }
}

/// Reads the `TVFocusElevationKey` published by the cell's focusable and raises `zIndex` while it's
/// focused, so the render-transform lift paints over every sibling instead of under later ones.
/// `zIndex` is binary (not animated), so the cell pops above the moment focus lands and drops back
/// as the next cell takes focus — matching how the focus engine floats `.card`-styled cells.
private struct TVFocusElevationModifier: ViewModifier {
    @State private var elevated = false

    func body(content: Content) -> some View {
        content
            .zIndex(elevated ? 1 : 0)
            .onPreferenceChange(TVFocusElevationKey.self) { elevated = $0 }
    }
}
#endif
