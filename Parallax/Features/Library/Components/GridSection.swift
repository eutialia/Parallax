import SwiftUI

/// A titled group of content within a scrolling wall — a heading, an optional count, then whatever
/// the caller draws beneath it.
///
/// Shared by the search results (Shows / Movies / Episodes) and the Favorites wall (one section per
/// server). Title-cased rather than uppercased, because Favorites' headings are server names the
/// user typed: shouting "LIVING ROOM" back at them is wrong in a way that "FOLDERS" isn't. That's
/// also why `SMBBrowseView` keeps its own uppercase `SMBBrowseSection` — those headings are category
/// labels, a different kind of word, and folding them in here would only serve tidiness.
///
/// Takes plain content rather than owning a grid: the two callers need different column counts per
/// section (search mixes poster and landscape rows), and Favorites needs to swap the grid for a
/// failure row.
struct GridSection<Content: View>: View {
    let title: String
    /// Shown beside the title when non-nil. Passing nil suppresses it for sections whose count
    /// isn't meaningful yet — a section that failed to load has no number to report.
    var count: Int? = nil
    /// Overrides the VoiceOver noun ("5 results" in search, "5 items" on the Favorites wall).
    var countNoun: String = "item"
    @ViewBuilder let content: Content

    @Environment(\.appIdiom) private var idiom

    var body: some View {
        // tvOS: leave focus-safe headroom under the title (see `AppLayout.focusSafeHeaderGap`,
        // same idiom as `MetadataRow`'s shelf header, tuned separately for this grid's taller tiles).
        VStack(alignment: .leading, spacing: AppLayout.focusSafeHeaderGap(idiom: idiom)) {
            HStack(spacing: 6) {
                Text(title).font(.cardHeaderTitle)
                if let count {
                    Text("\(count)").font(.subheadline).foregroundStyle(Color.secondaryLabel)
                }
            }
            // One header stop: VoiceOver reads "Shows, 5 results" instead of "Shows" then a stray
            // "5" as a separate element.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityAddTraits(.isHeader)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var accessibilityLabel: String {
        guard let count else { return title }
        return "\(title), \(count) \(countNoun)\(count == 1 ? "" : "s")"
    }
}
