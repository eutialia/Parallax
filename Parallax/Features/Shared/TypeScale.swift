import SwiftUI

/// Dynamic-Type-aware custom font sizing.
///
/// `Font.system(size:weight:design:)` is a FIXED point size — it ignores the user's
/// text-size setting. The design specifies custom display sizes (e.g. the 52pt hero
/// title) that must keep their *magnitude* yet still scale for accessibility. The
/// system-provided way to do that is `@ScaledMetric`, which scales a base value along a
/// chosen text style's Dynamic Type ramp. This wraps that in a one-liner so call sites
/// stay readable and every custom size scales the same way:
///
///     Text(title).scaledFont(52, relativeTo: .largeTitle, weight: .heavy)
///
/// Prefer a plain text style (`.font(.title2)`, `.headline`, …) whenever the design size
/// is close to a standard one — those already scale. Reach for `scaledFont` only for
/// bespoke display sizes that have no nearby text style.
extension View {
    func scaledFont(
        _ size: CGFloat,
        relativeTo textStyle: Font.TextStyle,
        weight: Font.Weight = .regular,
        design: Font.Design = .default
    ) -> some View {
        modifier(ScaledFont(size: size, relativeTo: textStyle, weight: weight, design: design))
    }
}

private struct ScaledFont: ViewModifier {
    @ScaledMetric private var size: CGFloat
    private let weight: Font.Weight
    private let design: Font.Design

    init(size: CGFloat, relativeTo textStyle: Font.TextStyle, weight: Font.Weight, design: Font.Design) {
        _size = ScaledMetric(wrappedValue: size, relativeTo: textStyle)
        self.weight = weight
        self.design = design
    }

    func body(content: Content) -> some View {
        content.font(.system(size: size, weight: weight, design: design))
    }
}
