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
/// the 10-foot UI (`.headline` ≈ 38pt), reading oversized against the whole screen — so tvOS gets
/// fixed, calmer sizes. They stay ON or ABOVE Apple's tvOS legibility ramp, though: the HIG sets a
/// 23pt MINIMUM / 29pt default at 10 feet (Caption 2 = 23, Caption 1 = 25, Body = 29, Callout = 31),
/// so the smallest tokens here floor at 23 — anything dimmer/smaller is unreadable from the couch.
/// iOS keeps the semantic styles unchanged. One home for these so the row surfaces can't drift apart.
extension Font {
    /// Primary row/card title (servers, sources, settings cards). tvOS `Callout`. iOS `.headline`.
    static var rowTitle: Font {
        #if os(tvOS)
        .system(size: 31, weight: .semibold)
        #else
        .headline
        #endif
    }

    /// Secondary caption line under a row title. tvOS `Caption 2` (the 23pt floor). iOS `.caption`.
    static var rowSubtitle: Font {
        #if os(tvOS)
        .system(size: 23, weight: .regular)
        #else
        .caption
        #endif
    }

    /// A settings row's body label (plain action rows). tvOS `Body` (the 29pt default). iOS `.body`.
    static var rowBody: Font {
        #if os(tvOS)
        .system(size: 29, weight: .regular)
        #else
        .body
        #endif
    }

    /// The centered secondary line under the auth brand mark ("Choose how to connect"). tvOS
    /// `Caption 1`. iOS `.subheadline`.
    static var authSubtitle: Font {
        #if os(tvOS)
        .system(size: 25, weight: .regular)
        #else
        .subheadline
        #endif
    }

    /// Uppercase group header above a settings section ("SERVERS", "STORAGE", "THIS SERVER"). tvOS
    /// `Caption 2` (the 23pt floor; all-caps per the tvOS subheading convention). iOS `.footnote` semibold.
    static var sectionHeader: Font {
        #if os(tvOS)
        .system(size: 23, weight: .semibold)
        #else
        .footnote.weight(.semibold)
        #endif
    }

    /// A connected-server / detail card's HEADER title (bigger than `.rowTitle`). tvOS sits between
    /// Callout and Headline so it leads the card. iOS `.title3` bold.
    static var cardHeaderTitle: Font {
        #if os(tvOS)
        .system(size: 34, weight: .bold)
        #else
        .title3.weight(.bold)
        #endif
    }

    /// The host/detail line under a card header. tvOS `Caption 1`. iOS `.subheadline`.
    static var cardHeaderSubtitle: Font {
        #if os(tvOS)
        .system(size: 25, weight: .regular)
        #else
        .subheadline
        #endif
    }

    /// The persistent tvOS settings-rail page heading (`TVSettingsRail`), hung under the pinned app
    /// icon. tvOS-only by construction; lives here so the rail draws no raw `.system(size:)` of its
    /// own — TypeScale stays the single home for the 10-foot scale. Sits a touch above the 23pt floor.
    static var railHeading: Font { .system(size: 26, weight: .medium) }
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
