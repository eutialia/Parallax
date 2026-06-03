import SwiftUI

struct MetadataRow<Item: Identifiable & Hashable, Content: View>: View {
    let title: String
    let items: [Item]
    let tileWidth: CGFloat
    @ViewBuilder let content: (Item) -> Content

    @Environment(\.horizontalSizeClass) private var hSize

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
                .padding(.horizontal, ContentInset.horizontal(hSize))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(items) { item in
                        content(item)
                            .frame(width: tileWidth)
                    }
                }
                .padding(.horizontal, ContentInset.horizontal(hSize))
            }
        }
    }
}
