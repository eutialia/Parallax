import SwiftUI
import ParallaxJellyfin

/// The Apple-TV / Infuse-style hero band used by the movie/series detail header. It is
/// built from two layers that deliberately share **no** modifiers, which is the whole point:
///
///  • **Backdrop** — full-bleed artwork flush to the detail column’s leading edge.
///    On iPad regular width it uses Apple’s `backgroundExtensionEffect()` (same approach
///    as the Landmarks sample and HIG “Adopting Liquid Glass”): the leading strip is
///    mirrored + blurred under the floating sidebar — **not** real content scrolled
///    underneath. The image is `.clipped()` before the effect with a **hard bottom**
///    edge (no bottom fade on the artwork layer — fading there bleeds into the
///    mirrored strip and exaggerates the sidebar seam). Legibility is foreground-only.
///
///  • **Foreground** — kicker, title, metadata, Play + glass actions, inset with
///    `safeAreaPadding` so controls stay in the readable column.
///
/// Parent `ScrollView`s should use `.scrollClipDisabled(true)` and
/// `.ignoresSafeArea(edges: .top)`. That — not any offset math here — is what makes
/// the hero paint under the status bar / sidebar: the parent drops the top content
/// inset, so this band sits at y=0 and its artwork fills up to the screen edge.
/// iPhone uses a 2:3 poster band; iPad uses 16:9 landscape. Keep the hero flush to
/// the leading edge (no horizontal padding on its container).
///
/// The recently-added Home hero is `HomeHeroCarousel` (a SwiftUI crossfade), not this band;
/// both share `HeroMetrics` so their geometry stays in lockstep.
struct HeroBackdrop<Backdrop: View, Foreground: View>: View {
    @ViewBuilder var backdrop: () -> Backdrop
    @ViewBuilder var foreground: () -> Foreground

    @Environment(\.horizontalSizeClass) private var hSize

    private var regularWidth: Bool { hSize == .regular }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            backdrop()
                .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                .clipped()
                .backgroundExtensionEffect(isEnabled: regularWidth)
                .allowsHitTesting(false)

            foreground()
                .frame(maxWidth: HeroMetrics.contentMaxWidth, alignment: .leading)
                .modifier(HeroForegroundLegibility())
                .safeAreaPadding(.horizontal, hSize == .regular ? Space.s40 : Space.s22)
                .padding(.bottom, Space.s30)
        }
        .heroBandFrame(regularWidth: regularWidth)
    }
}

/// Shared hero geometry so the Home `HomeHeroCarousel` and the detail `HeroBackdrop` can't
/// drift apart. A plain namespace (not a static on the generic `HeroBackdrop`, which would
/// force callers to spell out its two type parameters just to read a constant).
enum HeroMetrics {
    /// Readable column width for hero foreground content (title, meta, actions).
    static let contentMaxWidth: CGFloat = 720
    /// Band aspect ratio (width ÷ height): 2:3 poster on iPhone, 16:9 landscape on iPad.
    static func bandAspectRatio(regularWidth: Bool) -> CGFloat {
        regularWidth ? JellyfinImage.landscape : JellyfinImage.poster
    }
    /// Band height for layout math (overscroll zoom, etc.).
    static func height(containerWidth: CGFloat, regularWidth: Bool) -> CGFloat {
        containerWidth / bandAspectRatio(regularWidth: regularWidth)
    }
}

/// Sizes the hero band from container width and the platform aspect ratio.
struct HeroBandFrame: ViewModifier {
    let regularWidth: Bool

    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity)
            .aspectRatio(HeroMetrics.bandAspectRatio(regularWidth: regularWidth), contentMode: .fit)
    }
}

extension View {
    func heroBandFrame(regularWidth: Bool) -> some View {
        modifier(HeroBandFrame(regularWidth: regularWidth))
    }
}

/// Keeps hero labels readable over bright artwork without a boxed background. Shared by the
/// detail `HeroBackdrop` and the Home `HeroForeground` so the treatment stays identical.
struct HeroForegroundLegibility: ViewModifier {
    func body(content: Content) -> some View {
        content
            .shadow(color: .black.opacity(0.7), radius: 2, x: 0, y: 1)
            .shadow(color: .black.opacity(0.35), radius: 14, x: 0, y: 0)
    }
}

// MARK: - Preview harness

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
                .scrollClipDisabled(true)
                .background(Color.background)
                .toolbar(.hidden, for: .navigationBar)
                .ignoresSafeArea(edges: .top)
            }
        }
        Tab("Library", systemImage: "rectangle.stack") { Color.background }
        // Role-less to match the real Search tab (see RootTabView) — `role: .search`
        // hoists the field into the iPadOS 26 sidebar chrome, which the app avoids.
        Tab("Search", systemImage: "magnifyingglass") { Color.background }
    }
    .tabViewStyle(.sidebarAdaptable)
}
