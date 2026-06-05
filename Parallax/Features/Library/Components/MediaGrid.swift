import SwiftUI

/// Column layout for poster grids: a fixed count of flexible columns, or — when `fixedColumns`
/// is nil — adaptive by `columnMinWidth`. Shared by `MediaGrid` and the poster loading
/// skeletons so the loading and loaded grids stay column-for-column aligned.
func posterGridColumns(fixedColumns: Int?, columnMinWidth: CGFloat) -> [GridItem] {
    if let fixedColumns {
        return Array(repeating: GridItem(.flexible(), spacing: Space.s12, alignment: .top), count: fixedColumns)
    }
    return [GridItem(.adaptive(minimum: columnMinWidth), spacing: Space.s12, alignment: .top)]
}

struct MediaGrid<Item: Identifiable & Hashable, Content: View>: View {
    let items: [Item]
    let columnMinWidth: CGFloat
    /// Fixed column count; when nil the grid adapts by `columnMinWidth`.
    let fixedColumns: Int?
    @ViewBuilder let content: (Item) -> Content
    let onAppearLast: (() -> Void)?

    init(
        items: [Item],
        columnMinWidth: CGFloat = 140,
        fixedColumns: Int? = nil,
        onAppearLast: (() -> Void)? = nil,
        @ViewBuilder content: @escaping (Item) -> Content
    ) {
        self.items = items
        self.columnMinWidth = columnMinWidth
        self.fixedColumns = fixedColumns
        self.onAppearLast = onAppearLast
        self.content = content
    }

    var body: some View {
        let columns = posterGridColumns(fixedColumns: fixedColumns, columnMinWidth: columnMinWidth)
        LazyVGrid(columns: columns, spacing: 16) {
            ForEach(items) { item in
                content(item)
                    .onAppear {
                        if item == items.last { onAppearLast?() }
                    }
            }
        }
        // Leading/trailing inset is applied by the host ScrollView via
        // `.contentMargins` (one shared value, keeps the scroll indicator at
        // the edge) — the grid itself stays inset-free.
    }
}
