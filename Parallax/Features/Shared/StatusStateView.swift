import SwiftUI

/// The app's single empty / error placeholder. Every "glyph + title + message" state —
/// Home's failed feed, an empty library, a search with no hits, a detail that wouldn't
/// load — renders through here so they share one layout, one set of metrics, and one
/// centering rule.
///
/// Wraps the system `ContentUnavailableView` to inherit its glyph/title/description
/// metrics, Dynamic Type, and dark-mode treatment, then fills the vertical viewport so
/// the content sits optically centered instead of pinned to the top. That last part is
/// what a bare `ContentUnavailableView` can't do on its own inside a `ScrollView`: the
/// scroll view proposes an unbounded height, so the view takes its compact ideal size and
/// hugs the top edge (the bug this consolidated — Home's "Couldn't load" was top-padded
/// inside its feed `ScrollView`). `containerRelativeFrame(.vertical)` pins it to the
/// scroll viewport's height; outside a scroll view it reads the enclosing container, so a
/// plain navigation/detail surface centers identically.
struct StatusStateView: View {
    let title: String
    let systemImage: String
    /// Optional supporting line under the title — a server error message, or a one-line
    /// hint for an empty state. Omitted states render title + glyph only.
    let message: String?

    init(title: String, systemImage: String, message: String? = nil) {
        self.title = title
        self.systemImage = systemImage
        self.message = message
    }

    /// The recurring load-failure variant — the `exclamationmark.triangle` glyph with a
    /// server/error message. Six screens (Home, both library views, search, movie + series
    /// detail) rendered it verbatim; this is the one spelling of it.
    static func failure(_ title: String, message: String) -> StatusStateView {
        StatusStateView(title: title, systemImage: "exclamationmark.triangle", message: message)
    }

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            if let message {
                Text(message)
            }
        }
        // Vertical only: `ContentUnavailableView` already fills its width greedily and
        // centers its glyph/title/message within it, so horizontal centering holds even
        // under a leading-aligned parent (Home's shelves VStack) — don't add `.horizontal`
        // to "fix" an alignment that isn't broken.
        .containerRelativeFrame(.vertical)
    }
}

#if DEBUG
/// The exact Home scenario: a failed state inside a feed `ScrollView`. Proves the state
/// centers in the viewport rather than pinning under the top edge.
#Preview("Failure · in ScrollView") {
    ScrollView {
        StatusStateView.failure("Couldn't load Home", message: "The Internet connection appears to be offline.")
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color.background)
    .preferredColorScheme(.dark)
}

#Preview("Empty · plain surface") {
    StatusStateView(
        title: "No Favorites",
        systemImage: "heart",
        message: "Movies and shows you favorite will show up here."
    )
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color.background)
    .preferredColorScheme(.dark)
}
#endif
