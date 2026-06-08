import SwiftUI

/// Visual treatment for a full-width form CTA (auth + settings).
enum FormActionStyle {
    /// Bright `buttonFill` pill — the screen's #1 action (Connect).
    case solid
    /// Frosted glass pill — secondary actions (Quick Connect, Add Server, …).
    case glass
}

/// Shared metrics for full-width form controls (text fields + CTA pills) so a screen's
/// fields and buttons stay the same height.
enum FormControl {
    /// Resting height for a full-width form control: the Dynamic-Type-`scaled` iOS value,
    /// floored at `AppLayout.tvControlHeight` on tvOS (at 50pt the 10-foot label nearly
    /// filled the pill and read as cramped).
    static func height(idiom: AppIdiom, scaled: CGFloat) -> CGFloat {
        idiom == .tv ? max(scaled, AppLayout.tvControlHeight) : scaled
    }
}

extension View {
    /// Lay a label out as a full-width form CTA: headline text, the shared `FormControl`
    /// height, and the solid/glass background drawn **inside** the label so an enclosing
    /// `tvChipButton()` scales the whole pill uniformly on focus. A background applied
    /// *outside* the label would stay put while only the text lifts (the focus effect reads
    /// the focusable's label, not its siblings). Pair with `.tvChipButton()` on the
    /// Button/NavigationLink so tvOS shows the gentle glass lift instead of the system focus
    /// platter (`.plain`/`.automatic` are system styles and paint that platter on Apple TV).
    func formActionLabel(_ style: FormActionStyle) -> some View {
        modifier(FormActionLabel(style: style))
    }
}

private struct FormActionLabel: ViewModifier {
    let style: FormActionStyle

    @Environment(\.appIdiom) private var idiom
    @ScaledMetric(relativeTo: .headline) private var baseHeight: CGFloat = 50

    @ViewBuilder
    func body(content: Content) -> some View {
        // Solid pill draws a token-fill rounded field; glass pill reuses the app's `glassPanel`.
        let sized = content
            .font(.headline)
            .foregroundStyle(style == .solid ? Color.buttonLabel : Color.label)
            .frame(maxWidth: .infinity)
            .frame(height: FormControl.height(idiom: idiom, scaled: baseHeight))
        switch style {
        case .solid:
            sized.background(Color.buttonFill, in: RoundedRectangle(cornerRadius: Radius.field, style: .continuous))
        case .glass:
            sized.glassPanel(cornerRadius: Radius.field)
        }
    }
}
