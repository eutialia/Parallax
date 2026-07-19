import SwiftUI

/// Visual treatment for a full-width form CTA (auth + settings). FLAT — Liquid Glass is reserved
/// for the player + system bars.
enum FormActionStyle {
    /// Bright `buttonFill` pill — the screen's #1 action (Connect). Deep ink by day, white by night.
    case solid
    /// Secondary flat pill — `fill` + hairline (Quick Connect, Add Server, …).
    case glass
}

extension View {
    /// Lay a label out as a full-width form CTA: `.rowTitle` type (`.headline` on iOS, a tamer 26pt
    /// on tvOS), full width, at the shared 50pt control height (62 on tvOS) so it matches the text
    /// fields stacked above it. The label COLOR + fill come from `formActionButton(_:)`'s style, which
    /// owns the focus inversion (and tints the spinner to match — see there). Pass `isWorking: true`
    /// to lead the title with a spinner: the title STAYS VISIBLE, because on the connect flows it
    /// morphs to "Cancel" and is the user's only way out of an in-flight attempt — hiding it read as
    /// a frozen blank pill on Apple TV (the tvOS SMB "stuck on Connect" report).
    func formActionLabel(isWorking: Bool = false) -> some View {
        modifier(FormActionLabelModifier(isWorking: isWorking))
    }

    /// Apply to the Button/NavigationLink wrapping a `formActionLabel` label. Draws the FLAT fill:
    /// `.solid` = solid `buttonFill`; `.glass` = `fill` + hairline. On tvOS the pill inverts to the
    /// HIG white platter + ink label and lifts on focus (the one focus treatment every flat control
    /// shares); iOS dims on press / when disabled.
    func formActionButton(_ style: FormActionStyle) -> some View {
        buttonStyle(FlatFormButtonStyle(role: style))
    }
}

/// Sizes the CTA label (full width, shared control height) and leads it with a spinner while
/// working. Color is the button style's job (it knows focus/enabled): it foregrounds the title and
/// TINTS the spinner in one place, so both stay legible on every fill — `buttonFill` is pure white
/// in dark mode, where an untinted spinner rendered white-on-white and the working button showed
/// NOTHING (the tvOS SMB "stuck on Connect" report).
private struct FormActionLabelModifier: ViewModifier {
    var isWorking = false
    #if !os(tvOS)
    /// Matches the iOS text fields' `baseControlHeight` so the CTA reads as the same height; scales
    /// with Dynamic Type so the label never clips.
    @ScaledMetric(relativeTo: .headline) private var height: CGFloat = 50
    #endif

    func body(content: Content) -> some View {
        HStack(spacing: Space.s12) {
            if isWorking { ProgressView() }
            content
        }
        .font(.rowTitle)
        .frame(maxWidth: .infinity)
        .frame(height: ctaHeight)
    }

    private var ctaHeight: CGFloat {
        #if os(tvOS)
        // Ride the shared hero/detail control-height family (62 on tvOS) instead of a bespoke 66, so
        // the form CTA matches the Play pill / circle actions rather than diverging.
        ActionRow.controlHeight(.tv)
        #else
        height
        #endif
    }
}

/// Flat form CTA: solid `buttonFill` (primary) or `fill` + hairline (secondary). On focus (tvOS) it
/// inverts to the white platter + ink — platter ONLY, no scale lift: these CTAs are full-width, and
/// `tvFocusEffect`'s 1.06× lift overflows a full-width pill into the rows above/below it (the same
/// reason `tvMenuRowButton`/`tvFocusListRow` are platter-only). The compact Play pill / circle
/// actions keep the lift since they don't span the width. iOS dims on press, reads as unavailable
/// when disabled.
private struct FlatFormButtonStyle: ButtonStyle {
    let role: FormActionStyle
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        TVFocusReader { focused in
            configuration.label
                .foregroundStyle(labelColor(focused: focused))
                // The working spinner reads the tint, not the foreground — keep both on the same
                // focus-aware color or the spinner vanishes on the white fill/platter in dark mode.
                .tint(labelColor(focused: focused))
                .flatControlFill(focused: focused, rest: restFill, hairline: hairline, in: Capsule())
                .opacity(opacity(pressed: configuration.isPressed))
                .animation(.pressDim, value: configuration.isPressed)
        }
    }

    private var restFill: Color { role == .solid ? Color.buttonFill : Color.fill }
    private var hairline: Color? { role == .solid ? nil : Color.separator }

    private func labelColor(focused: Bool) -> Color {
        if focused { return Color.playerInk }            // ink on the tvOS white focus platter
        // Disabled: re-resolve the label against the pill's OWN fill, not the page ink (page ink over
        // `buttonFill` lands ~1.1:1). The solid pill keeps off-white `buttonLabel` dimmed to 72% (legible
        // on the ink/white fill); the glass pill's ground is the page-tinted `fill`, where
        // `secondaryLabel` stays legible.
        if !isEnabled { return role == .solid ? Color.buttonLabel.opacity(0.72) : Color.secondaryLabel }
        return role == .solid ? Color.buttonLabel : Color.label
    }

    private func opacity(pressed: Bool) -> Double {
        if !isEnabled { return role == .solid ? 0.5 : 0.55 }
        return pressed ? 0.9 : 1
    }
}

#Preview("Form CTA parity") {
    VStack(spacing: Space.s22) {
        // Text-field stand-in at the shared form-control height — the CTAs below should read as the
        // same height (LoginView stacks them in one column).
        RoundedRectangle(cornerRadius: Radius.field, style: .continuous)
            .fill(Color.fill)
            .frame(height: 50)
            .overlay(
                Text("field · height 50")
                    .font(.footnote)
                    .foregroundStyle(Color.secondaryLabel)
            )
        Button {} label: {
            Text("Connect").formActionLabel()
        }
        .formActionButton(.solid)
        Button {} label: {
            Label("Use Quick Connect", systemImage: "bolt.fill").formActionLabel()
        }
        .formActionButton(.glass)
    }
    .padding(Space.s22)
    .background(Color.background)
}

#Preview("Form CTA parity · dark") {
    VStack(spacing: Space.s22) {
        RoundedRectangle(cornerRadius: Radius.field, style: .continuous)
            .fill(Color.fill)
            .frame(height: 50)
            .overlay(
                Text("field · height 50")
                    .font(.footnote)
                    .foregroundStyle(Color.secondaryLabel)
            )
        Button {} label: {
            Text("Connect").formActionLabel()
        }
        .formActionButton(.solid)
        Button {} label: {
            Label("Use Quick Connect", systemImage: "bolt.fill").formActionLabel()
        }
        .formActionButton(.glass)
    }
    .padding(Space.s22)
    .background(Color.background)
    .preferredColorScheme(.dark)
}

/// Disabled-state proof: the CTAs must read as DISABLED (dimmed but legible label), never a blank
/// pill. Left column enabled, right disabled.
private struct DisabledCTAProof: View {
    var body: some View {
        Grid(horizontalSpacing: Space.s18, verticalSpacing: Space.s22) {
            GridRow {
                cta(.solid, disabled: false)
                cta(.solid, disabled: true)
            }
            GridRow {
                cta(.glass, disabled: false)
                cta(.glass, disabled: true)
            }
        }
        .padding(Space.s22)
        .background(Color.background)
    }

    @ViewBuilder
    private func cta(_ style: FormActionStyle, disabled: Bool) -> some View {
        Button {} label: {
            Text(disabled ? "Disabled" : "Enabled").formActionLabel()
        }
        .formActionButton(style)
        .disabled(disabled)
    }
}

#Preview("CTA disabled state · light") {
    DisabledCTAProof().preferredColorScheme(.light)
}

#Preview("CTA disabled state · dark") {
    DisabledCTAProof().preferredColorScheme(.dark)
}
