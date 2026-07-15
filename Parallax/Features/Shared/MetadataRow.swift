import SwiftUI

struct MetadataRow<Item: Identifiable & Hashable, Content: View>: View {
    let title: String
    let items: [Item]
    let tileWidth: CGFloat
    @ViewBuilder let content: (Item) -> Content

    @Environment(\.appIdiom) private var idiom

    var body: some View {
        // tvOS posters wear the native `.borderless` focus lockup (~1.1× lift): a focused 2:3
        // tile's top edge rises ≈ height × (scale−1)/2 (≈16.5pt for the 330pt Home poster),
        // and `tvScrollClipDisabled()` lets it paint past the row bounds. At the old 8pt gap
        // that lift crossed into the section header, so give the header→row gap enough headroom
        // to clear the lift on tvOS. iPhone/iPad have no focus lift, so they keep the tight gap.
        VStack(alignment: .leading, spacing: idiom == .tv ? Space.s22 : Space.s8) {
            Text(title)
                // The TV shelf header rides `cardHeaderTitle` (34pt bold) — a proper 10-foot heading
                // that leads the shelf on the 5×-wider canvas; iPhone/iPad keep `.title2`. (The earlier
                // `.title3` read ~20pt on tv, smaller than iPhone's header.)
                .font(idiom == .tv ? .cardHeaderTitle : .title2.weight(.bold))
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

#if DEBUG
private struct ShelfPreviewTile: Identifiable, Hashable { let id: Int }

/// Focus-lift clearance check (render on the tvOS destination, dark mode). A 2:3 poster row under
/// a section header with the 2nd tile scaled 1.1× to stand in for the native `.borderless` focus
/// lockup — a static preview has no real focus. The red line marks the lifted tile's top edge; it
/// must sit BELOW the "Continue Watching" header. Proves the `idiom == .tv` header→row gap clears
/// the lift (the bug: at the old 8pt gap the lift crossed into the header).
#Preview("Shelf focus-lift clearance (tv)", traits: .fixedLayout(width: 900, height: 560)) {
    MetadataRow(
        title: "Continue Watching",
        items: (0..<5).map { ShelfPreviewTile(id: $0) },
        tileWidth: 220
    ) { tile in
        RoundedRectangle(cornerRadius: Radius.tile)
            .fill(Color.artworkPlaceholder)
            .aspectRatio(2.0 / 3.0, contentMode: .fit)
            .scaleEffect(tile.id == 1 ? 1.1 : 1.0, anchor: .center)
            .overlay(alignment: .top) {
                if tile.id == 1 { Rectangle().fill(.red).frame(height: 2) }
            }
    }
    .environment(\.appIdiom, .tv)
    .padding(.top, 80)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .background(Color.background)
    .preferredColorScheme(.dark)
}
#endif
