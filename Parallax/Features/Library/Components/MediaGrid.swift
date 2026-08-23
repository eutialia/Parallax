import SwiftUI

/// Column layout for poster grids: a fixed count of flexible columns. Shared by `MediaGrid` and
/// the poster loading skeletons so the loading and loaded grids stay column-for-column aligned.
func posterGridColumns(
    fixedColumns: Int,
    columnSpacing: CGFloat = Space.s12
) -> [GridItem] {
    Array(repeating: GridItem(.flexible(), spacing: columnSpacing, alignment: .top), count: fixedColumns)
}

struct MediaGrid<Item: Identifiable & Hashable, Content: View>: View {
    let items: [Item]
    let fixedColumns: Int
    @ViewBuilder let content: (Item) -> Content
    let onAppearLast: (() -> Void)?

    @Environment(\.appIdiom) private var idiom

    init(
        items: [Item],
        fixedColumns: Int,
        onAppearLast: (() -> Void)? = nil,
        @ViewBuilder content: @escaping (Item) -> Content
    ) {
        self.items = items
        self.fixedColumns = fixedColumns
        self.onAppearLast = onAppearLast
        self.content = content
    }

    var body: some View {
        let columns = posterGridColumns(
            fixedColumns: fixedColumns,
            columnSpacing: AppLayout.posterGridColumnSpacing(idiom: idiom)
        )
        LazyVGrid(columns: columns, spacing: AppLayout.posterGridRowSpacing(idiom: idiom)) {
            ForEach(items) { item in
                content(item)
                    .onAppear {
                        if item == items.last { onAppearLast?() }
                    }
            }
        }
        // The grid is one tvOS focus section so entering from outside diverts to the NEAREST
        // tile instead of the geometric projection. Without it, Down from the centered
        // header-controls row (itself a `focusSection`) aims at the middle column of the first
        // row — when the grid holds fewer items than that column index, no candidate exists
        // there and Down is silently dropped, stranding focus on the header.
        .tvFocusSection()
        // Leading/trailing inset is applied by the host ScrollView via
        // `.contentMargins` (one shared value, keeps the scroll indicator at
        // the edge) — the grid itself stays inset-free.
    }
}
