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
///
/// ONE screen height, not "whatever is left under the chrome": the trailing
/// `ignoresSafeArea` extends the centering region through the top and bottom safe areas
/// (inline nav bars, the search drawer, tab bars), so the message sits at the same screen
/// position on every surface. Without it, each host centered in its own leftover region —
/// SMB browse sat lower than Home by half its title bar, Search by half its drawer field
/// (the iPad empty-state "different heights" bug). Inside a full-bleed `ScrollView`
/// (Home) the viewport already spans the screen and the modifier is inert, so scroll and
/// non-scroll hosts land on the same optical center.
struct StatusStateView: View {
    /// What renders inside the shared centering shell.
    private enum Layout {
        case labeled(title: String, systemImage: String, message: String?)
        /// The system search "No Results" view — its localized phrasing isn't
        /// reproducible through `Label`, so it keeps its own case instead of a
        /// call site bypassing this wrapper (and silently losing the centering rule).
        case searchNoResults
    }

    private let layout: Layout

    init(title: String, systemImage: String, message: String? = nil) {
        layout = .labeled(title: title, systemImage: systemImage, message: message)
    }

    private init(layout: Layout) {
        self.layout = layout
    }

    /// The recurring load-failure variant — the `exclamationmark.triangle` glyph with a
    /// server/error message. Six screens (Home, both library views, search, movie + series
    /// detail) rendered it verbatim; this is the one spelling of it.
    static func failure(_ title: String, message: String) -> StatusStateView {
        StatusStateView(title: title, systemImage: "exclamationmark.triangle", message: message)
    }

    /// The system search empty state, routed through the shared centering shell.
    static let searchNoResults = StatusStateView(layout: .searchNoResults)

    /// The anchor the shell centers: the glyph+title unit's center — NOT the whole
    /// block's. Whole-block centering let the MESSAGE's line count move the anchor
    /// (device-measured: SMB's 2½-line share error hung its paragraph 10pt deeper and
    /// lifted its glyph 11pt higher than Search's one-liner, reading as misaligned
    /// screens even with identical containers). Pinning the glyph+title leaves copy
    /// length affecting only how far the message hangs below — which genuinely must
    /// vary — while the identity band sits at one screen position everywhere.
    private enum GlyphTitleCenter: AlignmentID {
        static func defaultValue(in context: ViewDimensions) -> CGFloat {
            context[VerticalAlignment.center]
        }
    }
    private static let glyphTitleCenter = VerticalAlignment(GlyphTitleCenter.self)

    var body: some View {
        Group {
            switch layout {
            case .labeled(let title, let systemImage, let message):
                // Spacing 0: the system view keeps its own breathing room under the
                // title, and adding stack spacing on top read as the message drifting
                // loose from the block (render-compared against the pre-split look).
                VStack(spacing: 0) {
                    // The glyph+title keeps `ContentUnavailableView` for its system
                    // metrics (glyph scale, title weight, Dynamic Type); fixedSize
                    // collapses its greedy height so the VStack hugs, and the guide
                    // exports this unit's center as the stack's anchor.
                    ContentUnavailableView {
                        Label(title, systemImage: systemImage)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .alignmentGuide(Self.glyphTitleCenter) { $0[VerticalAlignment.center] }
                    if let message {
                        // Mirrors the system description slot's styling (secondary
                        // subheadline, centered) — it left that slot only so the
                        // anchor above could exclude it.
                        Text(message)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                            // Cancels the label view's internal bottom padding so the
                            // title→message gap matches the system description slot
                            // (render-measured: 15.7pt bare vs the system's 6.7pt).
                            .padding(.top, -12)
                    }
                }
            case .searchNoResults:
                // Whole-block anchored (default guide): the system view is opaque, and
                // its fixed one-line description keeps the drift negligible.
                ContentUnavailableView.search
            }
        }
        // Position the composite so its ANCHOR (the glyph+title center — the custom
        // guide above; the plain center for the system search view) sits at this
        // frame's center. The frame fills whatever the CRF below establishes, so the
        // anchor lands at the container's midpoint on every host.
        .frame(
            maxWidth: .infinity, maxHeight: .infinity,
            alignment: Alignment(horizontal: .center, vertical: Self.glyphTitleCenter)
        )
        // Vertical only: the width is already greedy via the frame above, and
        // horizontal centering holds even under a leading-aligned parent (Home's
        // shelves VStack) — don't add `.horizontal` to "fix" an alignment that isn't
        // broken.
        .containerRelativeFrame(.vertical)
        // The one-screen-height rule (see the type comment), in two measured steps:
        // `ignoresSafeArea` alone TOP-ANCHORS the block — it expands the region the
        // subtree may occupy, but `containerRelativeFrame` has already sized the view
        // to the safe-area height, and the shorter child keeps its top-of-region
        // position instead of re-centering (render-measured: the block landed a full
        // chrome-height ABOVE center). The greedy frame in between fills the expanded
        // region and centers the CRF-sized block within it — and a centered block's
        // midpoint IS the region's midpoint, so the anchor frame above still lands on
        // the true screen center. In a full-bleed ScrollView (Home) this frame's
        // proposal is unbounded, so it collapses to the CRF height and both outer
        // modifiers are inert — scroll and non-scroll hosts land on the same screen
        // center. `.container` only: the keyboard region keeps shrinking the space, so
        // Search's idle prompt still centers above an open keyboard.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea(.container, edges: .vertical)
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

// iOS-host mimics only: inline-bar display mode, top-bar toolbar placement, and the
// drawer search field don't exist on tvOS (whose empty states render bare, like the
// previews above).
#if !os(tvOS)
/// The SMB browse shape: an inline nav title + trailing toolbar button above a bare
/// (non-scroll) empty state. Guards the one-screen-height rule — the glyph block must
/// center on the SCREEN, not in the shorter region under the bar (compare against
/// "Failure · in ScrollView" at the same canvas size; the two centers must match).
#Preview("Empty · under inline nav bar") {
    NavigationStack {
        StatusStateView(
            title: "Share Unavailable",
            systemImage: "externaldrive.badge.xmark",
            // The real share-root copy, verbatim: its 2–3 wrapped lines are the
            // variance this preview guards — the glyph+title must not move vs the
            // one-line-message previews.
            message: "The media share isn’t available on this server. It may be offline, renamed, or no longer shared. If it’s gone for good, remove it from this server in Settings."
        )
        .navigationTitle("media")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Sort", systemImage: "arrow.up.arrow.down") {}
            }
        }
    }
    .background(Color.background)
    .preferredColorScheme(.dark)
}

/// The Search shape: the drawer search field stacked under the nav bar, empty state
/// beneath — the tallest top chrome an empty state renders under. Same rule as above:
/// its center must match the other previews', not sit lower by half the drawer.
#Preview("Empty · under search drawer") {
    NavigationStack {
        StatusStateView(
            title: "Find something to watch",
            systemImage: "magnifyingglass",
            message: "Movies, shows, and episodes from your library."
        )
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .searchable(
            text: .constant(""),
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: "Search your library"
        )
    }
    .background(Color.background)
    .preferredColorScheme(.dark)
}
#endif
#endif
