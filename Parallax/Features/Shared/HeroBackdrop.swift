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
///    mirrored strip and exaggerates the sidebar seam). Legibility uses band-layer scrims
///    (iPhone: full-width bottom vignette; iPad: oval scrim centered on bottom-leading corner).
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

    @Environment(\.appIdiom) private var idiom

    private var regularWidth: Bool { idiom.usesLandscapeHeroBand }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .bottomLeading) {
                backdrop()
                    .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                    .clipped()
                    .tvPlatformGated { $0.backgroundExtensionEffect(isEnabled: regularWidth) }
                    .allowsHitTesting(false)

                heroBandScrim(
                    regularWidth: regularWidth,
                    bandWidth: geo.size.width,
                    bandHeight: geo.size.height
                )

                foreground()
                    .frame(maxWidth: HeroMetrics.contentMaxWidth, alignment: .leading)
                    .safeAreaPadding(.horizontal, HeroMetrics.foregroundHorizontalInset(regularWidth: regularWidth))
                    .padding(.bottom, HeroMetrics.foregroundBottomInset)
            }
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
    /// Overview blurb — tighter on iPad so three lines wrap sooner.
    static func overviewMaxWidth(regularWidth: Bool) -> CGFloat {
        regularWidth ? 480 : contentMaxWidth
    }
    /// Band aspect ratio (width ÷ height): 2:3 poster on iPhone, 16:9 landscape on iPad.
    static func bandAspectRatio(regularWidth: Bool) -> CGFloat {
        regularWidth ? JellyfinImage.landscape : JellyfinImage.poster
    }
    /// Band height for layout math (overscroll zoom, etc.).
    static func height(containerWidth: CGFloat, regularWidth: Bool) -> CGFloat {
        containerWidth / bandAspectRatio(regularWidth: regularWidth)
    }
    static let foregroundBottomInset: CGFloat = Space.s30
    static func foregroundHorizontalInset(regularWidth: Bool) -> CGFloat {
        regularWidth ? Space.s40 : Space.s22
    }
    /// Default `PrimaryPlayButton` height at `.headline` — matches its `@ScaledMetric` base.
    static let playButtonHeight: CGFloat = 46
    /// iPad oval scrim center, nudged from the artwork corner toward the play button.
    static func scrimCenterOffset(regularWidth: Bool) -> CGSize {
        guard regularWidth else { return .zero }
        return CGSize(
            width: foregroundHorizontalInset(regularWidth: true) + 120,
            height: foregroundBottomInset + playButtonHeight / 2
        )
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

// MARK: - Foreground legibility (HIG: background layer, not stacked text shadows)

/// iPhone — full-bleed bottom vignette over the artwork, behind the foreground column.
struct HeroBandBottomScrim: View {
    let bandHeight: CGFloat

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .black.opacity(0.4), location: 0.35),
                    .init(color: .black.opacity(0.72), location: 1),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: bandHeight * 0.62)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
    }
}

/// iPad — elliptical scrim over the artwork. Semi-axes = half band width/height; center
/// sits near the play button (`HeroMetrics.scrimCenterOffset`), not the raw corner.
struct HeroBandOvalScrim: View {
    let bandWidth: CGFloat
    let bandHeight: CGFloat

    private var horizontalRadius: CGFloat { bandWidth / 2 }
    private var verticalRadius: CGFloat { bandHeight / 2 }
    private var centerOffset: CGSize { HeroMetrics.scrimCenterOffset(regularWidth: true) }

    var body: some View {
        EllipticalGradient(
            stops: [
                .init(color: .black.opacity(0.40), location: 0),
                .init(color: .black.opacity(0.18), location: 0.62),
                .init(color: .clear, location: 1),
            ],
            center: .center,
            startRadiusFraction: 0,
            endRadiusFraction: 0.5
        )
        .frame(width: horizontalRadius * 2, height: verticalRadius * 2)
        .offset(
            x: -horizontalRadius + centerOffset.width,
            y: verticalRadius - centerOffset.height
        )
        .frame(width: bandWidth, height: bandHeight, alignment: .bottomLeading)
        .clipped()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        .allowsHitTesting(false)
    }
}

@ViewBuilder
func heroBandScrim(regularWidth: Bool, bandWidth: CGFloat, bandHeight: CGFloat) -> some View {
    if regularWidth {
        HeroBandOvalScrim(bandWidth: bandWidth, bandHeight: bandHeight)
    } else {
        HeroBandBottomScrim(bandHeight: bandHeight)
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
                                    .foregroundStyle(.white)
                                Text("Orbital")
                                    .scaledFont(52, relativeTo: .largeTitle, weight: .heavy)
                                    .foregroundStyle(.white).lineLimit(2).minimumScaleFactor(0.7)
                                HeroOverview(
                                    text: "A crew on humanity's last orbital station races to prevent a cascade failure.",
                                    regularWidth: true
                                )
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
