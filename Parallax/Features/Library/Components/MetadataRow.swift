import SwiftUI

struct MetadataRow<Item: Identifiable & Hashable, Content: View>: View {
    let title: String
    let items: [Item]
    let tileWidth: CGFloat
    @ViewBuilder let content: (Item) -> Content

    @Environment(\.appIdiom) private var idiom

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s8) {
            Text(title)
                // tvOS renders type a step larger than iOS at the same style; `.title2`
                // dominated the shelf there, so drop the TV header to `.title3` (still a
                // clear 10-foot heading) while iPhone/iPad keep `.title2`.
                .font(idiom == .tv ? .title3.weight(.bold) : .title2.weight(.bold))
                .padding(.horizontal, AppLayout.contentHMargin(idiom: idiom))
                .accessibilityAddTraits(.isHeader)
            ScrollView(.horizontal, showsIndicators: false) {
                // LazyHStack, not a plain HStack: a shelf realizes only the tiles near the
                // viewport, so off-screen tiles don't build their view tree, decode their
                // artwork, or hold a bitmap until focus scrolls them in. Identical layout to
                // an eager stack (same tiles, same spacing) — purely WHEN each tile is
                // instantiated — so there's no visual change on any platform; it just stops
                // every shelf from materialising its full item list at once. This is Apple's
                // own tvOS shelf recipe ("Creating a tvOS media catalog app in SwiftUI" →
                // Display content shelves: `ScrollView(.horizontal) { LazyHStack(spacing: 40) }
                // .scrollClipDisabled()`), which the lift below (`tvScrollClipDisabled`) matches.
                // 40pt inter-tile gap on tvOS (Apple's canonical focusable-tile spacing) so a
                // focused poster's lift doesn't crowd its neighbours.
                LazyHStack(alignment: .top, spacing: idiom == .tv ? Space.s40 : Space.s12) {
                    ForEach(items) { item in
                        content(item)
                            .frame(width: tileWidth)
                            .tvShelfItem()
                    }
                }
                .padding(.horizontal, AppLayout.contentHMargin(idiom: idiom))
            }
            // Group the whole scrollable shelf into one tvOS focus section (on the scroll
            // container, the conventional anchor — Apple's TV catalog sample) so vertical
            // entry from an adjacent shelf lands on the nearest tile and horizontal
            // traversal stays contained to this row until its edges.
            .tvFocusSection()
            // Let a focused tile's lift/shadow paint past the row bounds instead of being
            // clipped by the horizontal scroll view.
            .tvScrollClipDisabled()
        }
    }
}
