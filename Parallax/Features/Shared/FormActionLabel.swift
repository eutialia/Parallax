import SwiftUI

/// Visual treatment for a full-width form CTA (auth + settings). FLAT — Liquid Glass is reserved
/// for the player + system bars.
enum FormActionStyle {
    /// Bright `buttonFill` pill — the screen's #1 action (Connect). Espresso by day, white by night.
    case solid
    /// Secondary flat pill — `fill` + hairline (Quick Connect, Add Server, …).
    case glass
}

extension View {
    /// Lay a label out as a full-width form CTA: `.rowTitle` type (`.headline` on iOS, a tamer 26pt
    /// on tvOS), full width, at the shared 50pt control height (66 on tvOS) so it matches the text
    /// fields stacked above it. The label COLOR + fill come from `formActionButton(_:)`'s style, which
    /// owns the focus inversion. Pass `isWorking: true` to swap the label for a spinner WITHOUT
    /// resizing (the title stays hidden in the layout to drive the height; the spinner overlays).
    func formActionLabel(_ style: FormActionStyle, isWorking: Bool = false) -> some View {
        modifier(FormActionLabelModifier(style: style, isWorking: isWorking))
    }

    /// Apply to the Button/NavigationLink wrapping a `formActionLabel` label. Draws the FLAT fill:
    /// `.solid` = solid `buttonFill`; `.glass` = `fill` + hairline. On tvOS the pill inverts to the
    /// HIG white platter + ink label and lifts on focus (the one focus treatment every flat control
    /// shares); iOS dims on press / when disabled.
    func formActionButton(_ style: FormActionStyle) -> some View {
        buttonStyle(FlatFormButtonStyle(role: style))
    }
}

/// Sizes the CTA label (full width, shared control height) and swaps in the spinner while working.
/// Color is the button style's job (it knows focus/enabled), so this no longer sets a foreground.
private struct FormActionLabelModifier: ViewModifier {
    let style: FormActionStyle
    var isWorking = false
    #if !os(tvOS)
    /// Matches the iOS text fields' `baseControlHeight` so the CTA reads as the same height; scales
    /// with Dynamic Type so the label never clips.
    @ScaledMetric(relativeTo: .headline) private var height: CGFloat = 50
    #endif

    func body(content: Content) -> some View {
        content
            .font(.rowTitle)
            .frame(maxWidth: .infinity)
            .frame(height: ctaHeight)
            .opacity(isWorking ? 0 : 1)
            .overlay { spinner }
    }

    private var ctaHeight: CGFloat {
        #if os(tvOS)
        66
        #else
        height
        #endif
    }

    @ViewBuilder
    private var spinner: some View {
        if isWorking {
            ProgressView()
                #if !os(tvOS)
                .tint(style == .solid ? Color.buttonLabel : Color.label)
                #endif
        }
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
                .flatControlFill(focused: focused, rest: restFill, hairline: hairline, in: Capsule())
                .opacity(opacity(pressed: configuration.isPressed))
                .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
        }
    }

    private var restFill: Color { role == .solid ? Color.buttonFill : Color.fill }
    private var hairline: Color? { role == .solid ? nil : Color.separator }

    private func labelColor(focused: Bool) -> Color {
        if focused { return Color.playerInk }            // ink on the tvOS white focus platter
        if !isEnabled { return Color.secondaryLabel }    // legible gray on the dimmed pill
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
            Text("Connect").formActionLabel(.solid)
        }
        .formActionButton(.solid)
        Button {} label: {
            Label("Use Quick Connect", systemImage: "bolt.fill").formActionLabel(.glass)
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
            Text("Connect").formActionLabel(.solid)
        }
        .formActionButton(.solid)
        Button {} label: {
            Label("Use Quick Connect", systemImage: "bolt.fill").formActionLabel(.glass)
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
            Text(disabled ? "Disabled" : "Enabled").formActionLabel(style)
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
