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
            ScrollView(.horizontal, showsIndicators: false) {
                // 40pt inter-tile gap on tvOS (Apple's canonical focusable-tile spacing) so a
                // focused poster's lift doesn't crowd its neighbours.
                HStack(alignment: .top, spacing: idiom == .tv ? Space.s40 : Space.s12) {
                    ForEach(items) { item in
                        content(item)
                            .frame(width: tileWidth)
                            .tvShelfItem()
                            // Float the focused tile above its neighbours so its lift isn't painted
                            // under the cells to its right in the row. No-op on iOS.
                            .tvFocusElevated()
                    }
                }
                .padding(.horizontal, AppLayout.contentHMargin(idiom: idiom))
                .tvFocusSection()
            }
            // Let a focused tile's lift/shadow paint past the row bounds instead of being
            // clipped by the horizontal scroll view.
            .tvScrollClipDisabled()
        }
    }
}
