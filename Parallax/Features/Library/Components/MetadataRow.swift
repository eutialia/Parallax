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
                .font(.title2.weight(.bold))
                .padding(.horizontal, AppLayout.contentHMargin(idiom: idiom))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: idiom == .tv ? Space.s18 : Space.s12) {
                    ForEach(items) { item in
                        content(item)
                            .frame(width: tileWidth)
                            .tvShelfItem()
                    }
                }
                .padding(.horizontal, AppLayout.contentHMargin(idiom: idiom))
                .tvFocusSection()
            }
        }
    }
}
