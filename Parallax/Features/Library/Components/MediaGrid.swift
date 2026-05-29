import SwiftUI

struct MediaGrid<Item: Identifiable & Hashable, Content: View>: View {
    let items: [Item]
    let columnMinWidth: CGFloat
    @ViewBuilder let content: (Item) -> Content
    let onAppearLast: (() -> Void)?

    init(
        items: [Item],
        columnMinWidth: CGFloat = 140,
        onAppearLast: (() -> Void)? = nil,
        @ViewBuilder content: @escaping (Item) -> Content
    ) {
        self.items = items
        self.columnMinWidth = columnMinWidth
        self.onAppearLast = onAppearLast
        self.content = content
    }

    var body: some View {
        let columns = [GridItem(.adaptive(minimum: columnMinWidth), spacing: 12)]
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
