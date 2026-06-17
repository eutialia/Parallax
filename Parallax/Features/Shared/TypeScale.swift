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

/// tvOS-tamed type for the dense settings / auth row surfaces. The iOS semantic styles balloon on
/// the 10-foot UI (`.headline` ≈ 38pt, `.subheadline` ≈ 31pt), which read as oversized against the
/// whole screen — so tvOS gets fixed, calmer sizes (the same fixed-metric approach the player's
/// `MenuMetrics` uses for tvOS). iOS keeps the semantic styles unchanged. One home for these so the
/// row surfaces can't drift apart; tune the tvOS sizes here.
extension Font {
    /// Primary row/card title (servers, sources, settings cards). iOS `.headline`.
    static var rowTitle: Font {
        #if os(tvOS)
        .system(size: 26, weight: .semibold)
        #else
        .headline
        #endif
    }

    /// Secondary caption line under a row title. iOS `.caption`.
    static var rowSubtitle: Font {
        #if os(tvOS)
        .system(size: 18, weight: .regular)
        #else
        .caption
        #endif
    }

    /// A settings row's body label (plain action rows). iOS `.body`.
    static var rowBody: Font {
        #if os(tvOS)
        .system(size: 24, weight: .regular)
        #else
        .body
        #endif
    }

    /// The centered secondary line under the auth brand mark ("Choose how to connect"). iOS
    /// `.subheadline`.
    static var authSubtitle: Font {
        #if os(tvOS)
        .system(size: 22, weight: .regular)
        #else
        .subheadline
        #endif
    }

    /// Uppercase group header above a settings section ("SERVERS", "STORAGE", "THIS SERVER"). iOS
    /// `.footnote` semibold.
    static var sectionHeader: Font {
        #if os(tvOS)
        .system(size: 16, weight: .semibold)
        #else
        .footnote.weight(.semibold)
        #endif
    }

    /// A connected-server / detail card's HEADER title (bigger than `.rowTitle`). iOS `.title3` bold.
    static var cardHeaderTitle: Font {
        #if os(tvOS)
        .system(size: 30, weight: .bold)
        #else
        .title3.weight(.bold)
        #endif
    }

    /// The host/detail line under a card header. iOS `.subheadline`.
    static var cardHeaderSubtitle: Font {
        #if os(tvOS)
        .system(size: 20, weight: .regular)
        #else
        .subheadline
        #endif
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
