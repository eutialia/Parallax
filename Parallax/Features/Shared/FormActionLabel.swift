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
    /// `.solid` label to `buttonLabel`: the system does NOT flip the `.glassProminent`
    /// label against a light tint, so dark mode (white `buttonFill`) rendered
    /// white-on-white (pixel-verified in the "Form CTA parity · dark" preview). tvOS
    /// stays system-owned — the focused platter inverts the label, and a forced color
    /// breaks that.
    func formActionLabel(_ style: FormActionStyle) -> some View {
        self
            .font(.headline)
            .frame(maxWidth: .infinity)
            #if !os(tvOS)
            .foregroundStyle(style == .solid ? Color.buttonLabel : Color.label)
            #endif
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

