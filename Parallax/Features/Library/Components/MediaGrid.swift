import SwiftUI

/// Column layout for poster grids: a fixed count of flexible columns, or — when `fixedColumns`
/// is nil — adaptive by `columnMinWidth`. Shared by `MediaGrid` and the poster loading
/// skeletons so the loading and loaded grids stay column-for-column aligned.
func posterGridColumns(
    fixedColumns: Int?,
    columnMinWidth: CGFloat,
    columnSpacing: CGFloat = Space.s12
) -> [GridItem] {
    if let fixedColumns {
        return Array(repeating: GridItem(.flexible(), spacing: columnSpacing, alignment: .top), count: fixedColumns)
    }
    return [GridItem(.adaptive(minimum: columnMinWidth), spacing: columnSpacing, alignment: .top)]
}

struct MediaGrid<Item: Identifiable & Hashable, Content: View>: View {
    let items: [Item]
    let columnMinWidth: CGFloat
    /// Fixed column count; when nil the grid adapts by `columnMinWidth`.
    let fixedColumns: Int?
    @ViewBuilder let content: (Item) -> Content
    let onAppearLast: (() -> Void)?

    @Environment(\.appIdiom) private var idiom

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
        let columns = posterGridColumns(
            fixedColumns: fixedColumns,
            columnMinWidth: columnMinWidth,
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
        // Leading/trailing inset is applied by the host ScrollView via
        // `.contentMargins` (one shared value, keeps the scroll indicator at
        // the edge) — the grid itself stays inset-free.
    }
}
