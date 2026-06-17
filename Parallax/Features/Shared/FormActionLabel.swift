import SwiftUI

/// Visual treatment for a full-width form CTA (auth + settings).
enum FormActionStyle {
    /// Bright `buttonFill` pill — the screen's #1 action (Connect).
    case solid
    /// Frosted glass pill — secondary actions (Quick Connect, Add Server, …).
    case glass
}

extension View {
    /// Lay a label out as a full-width form CTA: headline type, full width. The chrome
    /// (platter, padding, press/focus treatment) comes from the NATIVE glass style
    /// applied by `formActionButton(_:)` on both platforms. iOS additionally pins the
    /// label color per `\.isEnabled`: the system does NOT flip the `.glassProminent`
    /// label against a light tint, so dark mode (white `buttonFill`) rendered
    /// white-on-white when ENABLED (hence the forced `buttonLabel`), and the dimmed
    /// DISABLED pill rendered the forced `buttonLabel` invisible (cream on a faint pill —
    /// the "blank Connect button" bug). So the disabled label drops to `secondaryLabel`,
    /// a legible gray on the dimmed pill (pixel-verified in "CTA disabled state"). tvOS
    /// stays system-owned — the focused platter inverts the label, and a forced color
    /// breaks that.
    func formActionLabel(_ style: FormActionStyle) -> some View {
        modifier(FormActionLabelModifier(style: style))
    }

    /// Apply to the Button/NavigationLink wrapping a `formActionLabel` label — the
    /// native Liquid Glass styles on BOTH platforms (one body; the system owns metrics,
    /// label color, press feedback, and the tvOS focus platter). `.solid` = prominent
    /// tinted with the brand `buttonFill`; `.glass` = plain glass.
    /// `controlSize(.extraLarge)` lands the iOS pill at ~50pt for a `.headline` label —
    /// the height the old hand-drawn chrome reserved and the iOS text fields still match via
    /// their `baseControlHeight` (tvOS has no controlSize; the style's own metrics rule, unchanged).
    @ViewBuilder
    func formActionButton(_ style: FormActionStyle) -> some View {
        switch style {
        case .solid:
            self.buttonStyle(.glassProminent)
                .tint(Color.buttonFill)
                #if !os(tvOS)
                .controlSize(.extraLarge)
                #endif
        case .glass:
            self.buttonStyle(.glass)
                #if !os(tvOS)
                .controlSize(.extraLarge)
                #endif
        }
    }
}

/// Picks the CTA label color from `\.isEnabled` so the disabled state stays legible — see
/// `formActionLabel(_:)` for why the enabled `.solid` label must be forced yet the disabled one
/// must not be. tvOS keeps the system-owned label (focus platter inverts it).
private struct FormActionLabelModifier: ViewModifier {
    let style: FormActionStyle
    #if !os(tvOS)
    @Environment(\.isEnabled) private var isEnabled
    #endif

    func body(content: Content) -> some View {
        content
            .font(.headline)
            .frame(maxWidth: .infinity)
            #if !os(tvOS)
            .foregroundStyle(labelColor)
            #endif
    }

    #if !os(tvOS)
    private var labelColor: Color {
        guard isEnabled else { return Color.secondaryLabel }
        return style == .solid ? Color.buttonLabel : Color.label
    }
    #endif
}

#Preview("Form CTA parity") {
    VStack(spacing: Space.s22) {
        // Text-field stand-in at the shared form-control height — the CTAs below
        // should read as the same height (LoginView stacks them in one column).
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

/// Disabled-state proof: the form CTAs must read as DISABLED (dimmed but legible label),
/// never as a blank pill. Relying on the native `.disabled()` of the glass styles — no manual
/// `.opacity()` stacked on top, which previously double-dimmed `.solid` into an unreadable
/// washed-out pill (the "invisible Connect button" bug). Left column enabled, right disabled.
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

