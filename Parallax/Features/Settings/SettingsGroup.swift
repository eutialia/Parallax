import SwiftUI

/// Shared geometry for the inset-grouped settings surface, so the section card, its rows, and the
/// hairlines that divide them line up from one source. Lifted from the redesign handoff (`sx.css`):
/// rows inset ~15–16pt, the inter-row hairline starts under the title past the leading glyph column.
enum SettingsMetrics {
    /// Horizontal inset of a row's content from the card edge. iOS keeps the handoff's ~16pt grouped-list
    /// inset; tvOS widens to the 10-foot scale (handoff `.tv-row{padding:0 26px}` ≈ 39pt on the 1920
    /// canvas, dialed to 34). The focus platter insets only `Space.s8` from the row, so this also sets the
    /// breathing room INSIDE the highlight chrome around the content (interior gap = rowHInset − 8).
    static var rowHInset: CGFloat {
        #if os(tvOS)
        34
        #else
        16
        #endif
    }
    /// Leading glyph column width (icon + gap to the title) — the SINGLE source `SettingsListRow`
    /// renders its glyph column at too, so the hairline (derived below) starts exactly at the title
    /// edge instead of 4px shy of it. The gap to the title is `Space.s12`.
    static let glyphColumn: CGFloat = 26
    /// Inset of the inter-row hairline so it begins under the title, clearing the glyph column — the
    /// iOS grouped-list look (`.row + .row::before{left:49px}`). = rowHInset + glyph + gap.
    static let rowSeparatorInset: CGFloat = rowHInset + glyphColumn + Space.s12
    /// Leading inset for the section header + footer text (handoff `.sec-hd/.sec-ft{padding:… 16px}`).
    static let headerInset: CGFloat = rowHInset
}

/// A one-pixel separator in `Color.separator`, optionally inset on the leading edge so it aligns under
/// a row's title the way iOS grouped lists do. Reads `displayScale` so the line stays a true hairline
/// at every Retina factor (and a crisp 1pt on the 10-foot tvOS canvas).
struct Hairline: View {
    @Environment(\.displayScale) private var displayScale
    var leadingInset: CGFloat = 0

    var body: some View {
        Rectangle()
            .fill(Color.separator)
            .frame(height: 1.0 / displayScale)
            .padding(.leading, leadingInset)
    }
}

/// The explanatory line under a settings section (handoff `.sec-ft` / `.tv-sec-ft`): the "Playback
/// preferences are coming…" / "Clearing won't remove…" footers. Present on every platform per the
/// parity rules — on tvOS it floors at the 23pt legibility minimum (`.rowSubtitle`) rather than the
/// mock's dense 16pt.
struct SettingsSectionFooter: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.rowSubtitle)
            .foregroundStyle(Color.secondaryLabel)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, SettingsMetrics.headerInset)
            .padding(.top, 2)
    }
}

/// One section of the redesigned settings / connect surface, expressed in each platform's native idiom:
///
/// - **iOS / iPadOS:** an inset-grouped card — an optional uppercase header, a rounded `Color.surface`
///   card whose rows are divided by leading-inset hairlines, then an optional explanatory footer. The
///   classic Settings.app inset-grouped list.
/// - **tvOS:** the same header / rows / footer, but the card is TRANSPARENT and the hairlines divide
///   rows that sit directly on the screen; only the FOCUSED row lifts into a white platter (the row's
///   own `tvFocusListRow()`), floating clear of the hairlines.
///
/// Rows are supplied as a plain `@ViewBuilder`; `Group(subviews:)` (the public iOS 18 container-subview
/// API) interleaves the hairline separators, so call sites stay a bare list of rows with no separator
/// bookkeeping. Supersedes the previous standalone-pill idiom (gaps, per-row capsules) in favour of the
/// handoff's grouped card.
struct SettingsGroup<Content: View>: View {
    var title: String?
    var footer: String?
    /// Leading inset for the inter-row hairline. Defaults to align under the title past the glyph
    /// column; pass 0 for a flush, edge-to-edge rule (rows with no leading glyph).
    var separatorInset: CGFloat = SettingsMetrics.rowSeparatorInset
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if let title {
                Text(title)
                    .font(.sectionHeader)
                    .textCase(.uppercase)
                    .foregroundStyle(Color.secondaryLabel)
                    .padding(.horizontal, SettingsMetrics.headerInset)
            }
            card
            if let footer {
                SettingsSectionFooter(footer)
            }
        }
    }

    private var card: some View {
        Group(subviews: content) { subviews in
            VStack(spacing: 0) {
                ForEach(Array(subviews.enumerated()), id: \.offset) { index, subview in
                    if index > 0 {
                        Hairline(leadingInset: separatorInset)
                    }
                    subview
                }
            }
        }
        .modifier(SettingsCardSurface())
    }
}

/// Paints the grouped card's surface: an opaque `Color.surface` rounded card on iOS/iPadOS; nothing on
/// tvOS, where the rows sit transparent on the screen and only the focused one lifts a platter.
private struct SettingsCardSurface: ViewModifier {
    func body(content: Content) -> some View {
        #if os(tvOS)
        content
        #else
        content
            .background(Color.surface)
            .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        #endif
    }
}
