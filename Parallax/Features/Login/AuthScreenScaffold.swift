import SwiftUI

/// Shared layout for the auth screens (sign-in card + Quick Connect): vertically centers
/// the card, caps its width, and scrolls instead of clipping when the content outgrows the
/// viewport (large Dynamic Type). Both modes wrap their card in this, so toggling between
/// them keeps the box pinned in the same spot on screen.
///
/// `minHeight: proxy.size.height` is what does the centering — the content is at least a
/// full viewport tall (so a short card sits dead-center) but is free to grow taller, which
/// keeps the ScrollView able to reach overflow instead of cutting it off.
struct AuthScreenScaffold<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                content
                    .frame(maxWidth: 444)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, Space.s18)
                    .padding(.vertical, Space.s40)
                    .frame(minHeight: proxy.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }
}
