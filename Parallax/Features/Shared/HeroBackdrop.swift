import SwiftUI
import ParallaxJellyfin

/// The Apple-TV / Infuse-style hero band shared by the Home featured hero and the
/// movie/series detail header. It is built from two layers that deliberately share
/// **no** modifiers, which is the whole point:
///
///  • **Backdrop** — the artwork, full-bleed across the content width and flush to the
///    leading edge, carrying `.backgroundExtensionEffect()`. On iPadOS the floating
///    glass sidebar leaves a leading safe-area inset; that modifier mirror-flips + blurs
///    a strip of the image's leading edge the width of the inset and tucks it *under* the
///    glass — so only a soft blurred reflection sits under the sidebar, never the crisp
///    pixels and never a control. It reads the **live** inset, so it reflows on its own
///    when the sidebar collapses. There is no hardcoded sidebar width anywhere.
///
///  • **Foreground** — kicker, title, metadata, Play + glass actions. An ordinary column
///    that is *not* given the effect and carries its own horizontal `safeAreaPadding`, so
///    its tap targets always stay in the readable area, clear of the sidebar.
///
/// This replaces the old `AmbientBackdrop`-as-a-fixed-aspect-box, whose controls were
/// glued bottom-leading *inside* the full-width image and therefore landed under the
/// floating sidebar (unclickable), and whose fixed box reflowed the whole hero whenever
/// the sidebar collapsed.
///
/// The backdrop is a generic slot so the app passes a `JellyfinImage` while the preview
/// harness passes a plain gradient (no live session needed to eyeball the bleed).
struct HeroBackdrop<Backdrop: View, Foreground: View>: View {
    /// Fixed band height (~520–560pt per the design). A predictable height keeps the
    /// content below it starting on a stable line and the foreground rhythm consistent.
    var height: CGFloat = 540
    @ViewBuilder var backdrop: () -> Backdrop
    @ViewBuilder var foreground: () -> Foreground

    @Environment(\.horizontalSizeClass) private var hSize

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            backdrop()
                .frame(height: height)
                .frame(maxWidth: .infinity)
                .clipped()
                // Scrim is part of the effect SOURCE (applied before the modifier) so the
                // mirrored under-sidebar strip fades to the page colour too — no hard
                // blurred band peeking out at the bottom under the glass.
                .overlay { scrim }
                .backgroundExtensionEffect()
                // Decorative only: never let the backdrop swallow taps meant for the
                // foreground's Play / Favorite buttons.
                .allowsHitTesting(false)

            foreground()
                // Cap to a readable column width; lead-align within it.
                .frame(maxWidth: Self.contentMaxWidth, alignment: .leading)
                // The ONE inset that keeps controls clear of the sidebar. `safeAreaPadding`
                // composes with the live sidebar inset (so it reflows on collapse) and adds
                // the design's content margin on top (iPad 40 / iPhone 22) — NOT a hardcoded
                // leading constant.
                .safeAreaPadding(.horizontal, hSize == .regular ? Space.s40 : Space.s22)
                .padding(.bottom, Space.s30)
        }
    }

    static var contentMaxWidth: CGFloat { 720 }

    /// Top-transparent → darkened lower third (text contrast) → page colour (so the band
    /// dissolves into the page instead of meeting it at a hard edge).
    private var scrim: some View {
        LinearGradient(
            stops: [
                .init(color: .clear, location: 0.0),
                .init(color: .black.opacity(0.55), location: 0.72),
                .init(color: Color.background, location: 1.0),
            ],
            startPoint: .top, endPoint: .bottom
        )
        .allowsHitTesting(false)
    }
}

// MARK: - Preview harness
//
// Embeds HeroBackdrop in a `.tabViewStyle(.sidebarAdaptable)` TabView with a GRADIENT
// backdrop (no live Session), so the floating-sidebar bleed + foreground clearance can be
// eyeballed on an iPad destination without a Jellyfin login. Render this on an iPad sim
// (regular width) to confirm: (a) the gradient bleeds a blurred edge UNDER the sidebar,
// (b) the title + Play button never tuck under it, (c) collapsing the sidebar reflows.

#Preview("HeroBackdrop · sidebar bleed") {
    TabView {
        Tab("Home", systemImage: "house") {
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: Space.s30) {
                        HeroBackdrop {
                            LinearGradient(
                                colors: [Color(red: 0.42, green: 0.20, blue: 0.55),
                                         Color(red: 0.0, green: 0.40, blue: 0.74)],
                                startPoint: .topLeading, endPoint: .bottomTrailing
                            )
                        } foreground: {
                            VStack(alignment: .leading, spacing: Space.s12) {
                                Text("FEATURED")
                                    .font(.caption.weight(.bold)).tracking(1.5)
                                    .foregroundStyle(.white.opacity(0.7))
                                Text("Orbital")
                                    .scaledFont(52, relativeTo: .largeTitle, weight: .heavy)
                                    .foregroundStyle(.white).lineLimit(2).minimumScaleFactor(0.7)
                                Text("2025 · 126 min")
                                    .font(.subheadline).foregroundStyle(.white.opacity(0.85))
                                Label("Play", systemImage: "play.fill")
                                    .font(.headline).foregroundStyle(Color.buttonLabel)
                                    .padding(.horizontal, Space.s22).frame(height: 46)
                                    .background(Color.buttonFill, in: Capsule())
                                    .padding(.top, Space.s8)
                            }
                        }
                        ForEach(0..<3) { i in
                            Text("Shelf \(i)")
                                .font(.headline)
                                .padding(.horizontal, Space.s40)
                            Rectangle().fill(Color.fill).frame(height: 120)
                                .padding(.horizontal, Space.s40)
                        }
                    }
                }
                .background(Color.background)
                .toolbar(.hidden, for: .navigationBar)
            }
        }
        Tab("Library", systemImage: "rectangle.stack") { Color.background }
        Tab("Search", systemImage: "magnifyingglass", role: .search) { Color.background }
    }
    .tabViewStyle(.sidebarAdaptable)
}
