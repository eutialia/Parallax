import SwiftUI

/// Shared layout for the auth screens (sign-in card + Quick Connect): places the card high in
/// the viewport, caps its width, and scrolls instead of clipping when the content outgrows the
/// viewport (large Dynamic Type). Both modes wrap their card in this, so the box stays in the same
/// spot when toggling between them.
///
/// The card is top-pinned with a fractional top inset rather than dead-centered, so it sits in the
/// upper third — the `ScrollView` keeps it reachable when the body grows past the viewport.
/// Shared auth-layout constants so the source picker's custom layout lines its mark up with the
/// scaffold-hosted screens (Settings, Quick Connect).
enum AuthLayout {
    /// Top inset as a fraction of the viewport height — lifts the card high in the viewport.
    static let topBias: CGFloat = 0.08
}

struct AuthScreenScaffold<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                content
                    #if os(tvOS)
                    .frame(maxWidth: 600)
                    #else
                    .frame(maxWidth: 444)
                    #endif
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, Space.s18)
                    // Top-pinned with a fractional inset (not min-height centering) so the card sits
                    // in the upper third; the ScrollView still reaches overflow when the body grows.
                    // Clamped to a sensible minimum so it never crowds the top on short viewports.
                    .padding(.top, max(Space.s26, proxy.size.height * AuthLayout.topBias))
                    .padding(.bottom, Space.s40)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        // The floor travels WITH the auth content, so the same screen reads identically as a sheet
        // root, a pushed page, or inside Settings. NavigationStack otherwise backs pushed views with
        // an opaque system background (white), which would read as a second surface over the sheet.
        .background(Color.background.ignoresSafeArea())
    }
}
