import SwiftUI

/// Hands a Button's (or Menu's) focus state to the chrome INSIDE its label, so the label
/// can swap fills per the tvOS HIG focus contract: a focused control inverts to an opaque
/// platter with dark content — translucent glass is the UNfocused look. A scale/shadow
/// lift alone (the old treatment) is nearly invisible at 10 feet; the fill inversion is
/// the signal users actually read. `@Environment(\.isFocused)` only reports the Button's
/// focus on its descendants, which is why this wrapper exists instead of a property on
/// the component view itself. Cross-platform on purpose: iOS simply always yields
/// `false`, so call sites need no `#if os` and chrome logic stays identical.
extension Animation {
    /// Shared focus-chrome timing: the platter/ink crossfade inside a focused control must
    /// run on the SAME curve as `TVFocusEffect`'s scale lift, or the chrome snaps while the
    /// control is still mid-scale (the "no transition" look vs the Apple TV app).
    static let tvFocusChrome = Animation.easeOut(duration: 0.18)
}

struct TVFocusReader<Content: View>: View {
    private let content: (Bool) -> Content

    @Environment(\.isFocused) private var isFocused

    // Explicit init, not a `@ViewBuilder` stored property: the implicit-memberwise form
    // trips Xcode's preview thunk (`__designTimeSelection` ambiguity) in every file that
    // uses the reader, killing #Preview there.
    init(@ViewBuilder content: @escaping (Bool) -> Content) {
        self.content = content
    }

    var body: some View {
        content(isFocused)
    }
}

extension View {
    /// Poster/artwork button style: NATIVE `.borderless` on tvOS — the system content
    /// lockup (lift + drop shadow + specular sheen + parallax tilt, all engine-driven and
    /// floated above grid siblings, none of which a custom style can fake). Pairs with
    /// `tvPosterHighlight(cornerRadius:)` on the tile INSIDE the label: the system masks
    /// its highlight to a default corner radius that mismatches ours, and the shaped
    /// content shape is what re-aligns it (device-verified June 2026 — the bare style's
    /// corner mismatch is reproduced in `PosterFocusSpikeScreen` row B). `.plain` on iOS.
    /// OWNS the button style — do NOT pair it with a separate `.buttonStyle(.plain)` at
    /// the call site: a nearer (inner) style wins and kills the focus effect, leaving the
    /// tile focus-dead on Apple TV. One style, set here, per control.
    @ViewBuilder
    func tvPosterButton() -> some View {
        #if os(tvOS)
        self.buttonStyle(.borderless)
        #else
        self.buttonStyle(.plain)
        #endif
    }

    /// Horizontal shelf-item button style: same native `.borderless` recipe as
    /// `tvPosterButton()` (see there for the label-side `tvPosterHighlight` pairing),
    /// `.plain` on iOS. Owns the button style; don't pair an inner `.buttonStyle(.plain)`
    /// (it wins and kills tvOS focus).
    @ViewBuilder
    func tvShelfItem() -> some View {
        #if os(tvOS)
        self.buttonStyle(.borderless)
        #else
        self.buttonStyle(.plain)
        #endif
    }

    /// Apply to the tile content INSIDE a `tvPosterButton()`/`tvShelfItem()` label, with
    /// the tile's own clip radius. tvOS: the system highlight (projection + specular +
    /// parallax, tvOS 17+) with its mask re-shaped to the tile's corners — without the
    /// content shape, the system masks to a default radius and dark tile corners poke
    /// out past the highlight on focus (the reason `.borderless` was originally
    /// rejected). No-op on iOS so the iPad pointer keeps its default behavior.
    @ViewBuilder
    func tvPosterHighlight(cornerRadius: CGFloat) -> some View {
        #if os(tvOS)
        self
            .hoverEffect(.highlight)
            .contentShape(.hoverEffect, .rect(cornerRadius: cornerRadius))
        #else
        self
        #endif
    }

    /// Chip/transport button style for controls that carry their OWN chrome (glass capsule,
    /// glass circle — the player chips and Settings server card; app-level buttons are
    /// native `.glass` and don't come through here). On tvOS a custom style that lifts via
    /// `tvFocusEffect()` (gentle scale + shadow) instead of the system `.card` platter,
    /// which drew a bright rounded box around the control and read as a
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

    /// Row style for items INSIDE a glass panel (the track menus): no system chrome and
    /// no scale lift — the row's own white platter (`TVFocusReader` in the label) is the
    /// whole focus affordance, and `tvChipButton()`'s 1.06 lift made a full-width row
    /// overflow its panel's edges on focus. `.plain` on iOS. Owns the button style.
    @ViewBuilder
    func tvMenuRowButton() -> some View {
        #if os(tvOS)
        self.buttonStyle(TVQuietButtonStyle())
        #else
        self.buttonStyle(.plain)
        #endif
    }

    /// Button style for a row in a grouped settings/picker list (the per-server cards' siblings:
    /// the "Sign Out" / "Make Active" rows, the source picker, the credential rows, the SMB folder
    /// browser). The quiet, no-chrome style avoids the `.plain` focus platter (a bright box that
    /// OVERFLOWS the row over its neighbours) and the `.borderless` content lockup (which lifts a
    /// leading SF Symbol into its own scaled, platter-backed glyph) — the row's own focus affordance
    /// comes from `tvFocusListRow()` on its LABEL. Same primitive as `tvMenuRowButton()` (the player
    /// track-menu rows); kept under this name for the settings-row call sites. Owns the button style.
    @ViewBuilder
    func tvListRowButton() -> some View {
        tvMenuRowButton()
    }

    /// tvOS focus affordance for a grouped-list row: paint the HIG focus platter CONTAINED to the
    /// row (an opaque white rounded fill that fades in on focus) and flip the row's `colorScheme`
    /// to `.light` so every semantic token inside (label / secondaryLabel / fill / red) resolves to
    /// its ink-on-white value for free — no per-view branch. Apply to the LABEL of a Button that
    /// uses `tvListRowButton()` (the label is a descendant of the focusable Button, so the reader's
    /// `\.isFocused` reports the Button's focus). Same recipe as the player track menu's `MenuRow`,
    /// minus the selection fill. No-op on iOS, where focus doesn't exist.
    ///
    /// Radius is `Radius.card` (not the smaller tile radius): on a tall 10-foot settings/credential
    /// row a 12pt corner barely curves and the platter read as a plain white rectangle — a card-sized
    /// radius makes the selection read as clearly rounded.
    @ViewBuilder
    func tvFocusListRow(cornerRadius: CGFloat = Radius.card) -> some View {
        #if os(tvOS)
        modifier(TVFocusListRowModifier(cornerRadius: cornerRadius))
        #else
        self
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

    /// `.focused(_:equals:)` for FocusState that only drives the tvOS focus engine —
    /// keeps call sites to one line instead of an `#if os(tvOS)` block each. No-op on iOS.
    @ViewBuilder
    func tvFocused<V: Hashable>(_ binding: FocusState<V>.Binding, equals value: V) -> some View {
        #if os(tvOS)
        self.focused(binding, equals: value)
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
/// scale + shadow) and dims slightly on press — no system `.card` platter. Applying
/// `tvFocusEffect()` to `configuration.label` works because the label is a descendant of the
/// focusable Button, so its `@Environment(\.isFocused)` reports the Button's focus.
struct TVGlassChipButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .tvFocusEffect()
    }
}

/// "Quiet" style: renders the label with NO system focus chrome and no lift — `.plain` on
/// tvOS paints the system focus platter (a bright rounded box) around the whole label.
/// For controls whose label carries its own focus affordance: the scrubber (handle grows +
/// outline ring in `.focused` mode — the platter swallowed the full-width bar) and the
/// track-menu rows (white platter via `TVFocusReader` — a lift overflows the panel).
/// Slight dim on press for Select feedback.
struct TVQuietButtonStyle: ButtonStyle {
    var pressedOpacity: Double = 0.85

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? pressedOpacity : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Paints a grouped-list row's focus platter (see `tvFocusListRow()`). Reads the enclosing Button's
/// focus via `TVFocusReader`, fades in an opaque white rounded fill BEHIND the row content, and
/// flips `colorScheme` to `.light` on focus so the content inverts to ink-on-white. The platter is
/// a fading layer (not a style swap, which would snap) on the same `.tvFocusChrome` curve as the
/// other focus chrome.
private struct TVFocusListRowModifier: ViewModifier {
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        TVFocusReader { focused in
            content
                .background(
                    // Inset so the platter FLOATS clear of the enclosing card's rounded corners.
                    // Edge-to-edge, the platter's corner radius mismatched the card's and left a dark
                    // crescent at the first/last row's corners (the visible "seam between two borders").
                    // A few points of margin makes it read as a deliberate floating selection instead.
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(.white.opacity(0.97))
                        .padding(.horizontal, Space.s8)
                        .padding(.vertical, Space.s3)
                        .opacity(focused ? 1 : 0)
                )
                .environment(\.colorScheme, focused ? .light : .dark)
                .animation(.tvFocusChrome, value: focused)
        }
    }
}

/// Reads the enclosing Button's focus and applies a uniform lift (scale + drop shadow, optional
/// brightness). It lives on the button's label (a descendant of the focusable Button), so
/// `isFocused` reports the Button's state — `ButtonStyleConfiguration` exposes only `isPressed`,
/// never focus, which is why a press-only custom style appears dead as focus moves across it on
/// Apple TV. Defaults are the gentle chip lift. (Posters no longer use this: they wear the
/// native `.borderless` lockup — see `tvPosterButton()`.)
private struct TVFocusEffect: ViewModifier {
    var scale: CGFloat = 1.06
    /// 0 by default: chips now invert to a white platter on focus (`TVFocusReader` in the
    /// label), and brightness stacked on white just clips.
    var brightness: Double = 0
    var shadowRadius: CGFloat = 18
    var shadowY: CGFloat = 12
    var animation: Animation = .tvFocusChrome

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
