import SwiftUI
import ParallaxJellyfin
import ParallaxCore

/// The Apple-TV / Infuse-style hero band — the single container behind BOTH the Home carousel
/// and the movie/series detail header. It is a dumb two-slot stacker and nothing more: it stacks
/// an `artwork` layer under a `foreground` column (bottom-leading), turns hits off on the artwork,
/// and places the column in the readable region. The ONLY effect it owns is the legibility
/// treatment (an idiom-split frosted fade); everything else is delegated, because the band's
/// effects don't all live at the same layer:
///
///  • **Legibility** (`HeroBottomFade` compact / `HeroCornerFade` landscape) sits BETWEEN the
///    artwork and the foreground, inserted here so all three call sites share one treatment. It
///    rides the foreground side of the stack (not baked into the artwork), so it stays out of the
///    iPad sidebar `backgroundExtensionEffect` reflection — only raw artwork is mirrored.
///  • **Artwork-bound** (clip, parallax offset, stretch scale, the sidebar extension effect) ride
///    the `artwork` slot, BELOW the legibility layer: parallax/stretch move the image while the
///    fade + title/actions stay put — that differential IS the parallax. The caller bakes them
///    into whatever it hands the slot (`HeroBandImage`'s `.heroBandExtension()` on detail; the
///    transformed `CrossfadeArtwork` on Home).
///  • **Foreground-bound** (`.id` + `.transition`) ride the `foreground` slot — Home hides the
///    column while dragging while the artwork keeps crossfading underneath.
///  • **Band-wrapping** (pan gesture, `onMoveCommand`, page dots) wrap the whole band at the Home
///    call site. Detail wraps it in nothing.
///
/// Sizing stays a call-site concern too (`heroBandFrame`): Home measures the band via a
/// `GeometryReader` to drive the stretch/pan, so it can't be framed from in here.
///
/// Parent `ScrollView`s should use `.scrollClipDisabled(true)` and `.ignoresSafeArea(edges: .top)`.
/// That — not any offset math here — is what makes the hero paint under the status bar / sidebar:
/// the parent drops the top content inset, so the band sits at y=0 and its artwork fills to the
/// screen edge. iPhone uses a 2:3 poster band; iPad/tvOS use 16:9 landscape.
///
/// SIDEBAR SEAM (pixel-bisected + control-rendered 2026-06-11; do not re-investigate): the 1-2px
/// hairline at the sidebar boundary is SYSTEM region-edge chrome — full window height, composited
/// above all app content, present with the extension effect disabled, on the loading skeleton, and
/// in a `NavigationSplitView` control render, so neither app-side layers nor a container migration
/// can remove it. Legibility now lives on the foreground fade, so `heroBandExtension` mirrors RAW
/// artwork under the sidebar — if a bright leading strip makes the seam resurface, re-add a faint
/// leading seam-guard wash (reuse `HeroScrim`). Details: memory `ipad-sidebar-pane-rim`.
struct HeroBand<Artwork: View, Foreground: View>: View {
    @ViewBuilder var artwork: () -> Artwork
    @ViewBuilder var foreground: () -> Foreground

    @Environment(\.appIdiom) private var idiom

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            artwork()
                .allowsHitTesting(false)
            // Legibility on the foreground side (stays out of the sidebar reflection). The tall
            // poster band gets a full-width bottom fade; the wide landscape band gets a corner-
            // focused glow so the darkening sits on the text, not the empty right side.
            if idiom == .compact {
                HeroBottomFade()
            } else {
                HeroCornerFade()
            }
            foreground()
                .heroForegroundPlacement(idiom: idiom)
        }
    }
}

/// Shared hero geometry so the Home `HomeHeroCarousel` and the detail `HeroBand` can't
/// drift apart. A plain namespace (not a static on the generic `HeroBand`, which would
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
        regularWidth ? MediaImage.landscape : MediaImage.poster
    }
    /// Half-speed parallax lag for a signed scroll adjustment (positive = pull-down
    /// rubber-band, negative = scrolled into the feed). Only the scrolled-down side
    /// shifts — pull-down belongs to the stretch zoom. The artwork rides at half the
    /// content's speed, the Apple-TV-style hero lag.
    static func parallaxShift(forScrollAdjustment value: CGFloat) -> CGFloat {
        max(0, -value) * 0.5
    }
    /// Stretch-zoom scale for a pull-down rubber-band: the artwork grows from its bottom
    /// edge to fill the gap. Only the positive side scales — the scrolled-down side
    /// belongs to `parallaxShift`; the two effects are mutually exclusive by sign.
    static func stretchScale(forScrollAdjustment value: CGFloat, bandHeight: CGFloat) -> CGFloat {
        guard bandHeight > 0 else { return 1 }
        return 1 + max(0, value) / bandHeight
    }
    /// tvOS hero height as a fraction of the viewport — deliberately NOT width-derived. A
    /// width-derived (`aspectRatio`) band grows taller when the `.sidebarAdaptable` menu
    /// collapses and the content widens; that shoves the bottom-anchored Play button down, and
    /// the focus engine scrolls the band's top off-screen with nothing focusable up there to
    /// scroll back. A constant viewport fraction holds the height steady across the sidebar
    /// collapse and leaves the first shelf peeking (Apple-TV Home convention), giving the focused
    /// controls room so tvOS has no reason to scroll at all.
    static let tvHeroHeightFraction: CGFloat = 0.82
    /// On tvOS the full-bleed hero fills the whole viewport, so its bottom-anchored controls
    /// must clear the ~60pt bottom overscan or a real TV clips the Play button. iPhone/iPad have
    /// no overscan, so they keep the tight inset.
    static func foregroundBottomInset(idiom: AppIdiom) -> CGFloat {
        idiom == .tv ? Space.s60 + Space.s12 : Space.s30
    }
    static func foregroundHorizontalInset(idiom: AppIdiom) -> CGFloat {
        switch idiom {
        case .compact: Space.s22
        case .regular: Space.s40
        // The hero artwork is full-bleed on tvOS (`heroScreenSafeArea()` drops the horizontal
        // safe area), so the foreground needs the overscan inset back in ABSOLUTE terms — it
        // isn't under the `tvContentInset()` wrapper that re-insets the shelves/body. This keeps
        // the title/Play column aligned with the shelves at `overscan + contentHMargin`.
        case .tv: AppLayout.tvOverscanInset + AppLayout.contentHMargin(idiom: .tv)
        }
    }
    /// Caps the hero foreground column so the title + actions never climb arbitrarily high up the
    /// band; the overview blurb flexes its line count to fill whatever height is left under that cap
    /// (see `AdaptiveHeroOverview`). A constant per idiom, not band-derived — the cap is the point.
    static func foregroundMaxHeight(idiom: AppIdiom) -> CGFloat {
        switch idiom {
        case .compact: 300
        case .regular: 340
        case .tv: 460
        }
    }
}

/// Sizes the hero band from container width and the platform aspect ratio.
struct HeroBandFrame: ViewModifier {
    let regularWidth: Bool

    func body(content: Content) -> some View {
        #if os(tvOS)
        // Constant viewport fraction, not width-derived — see `HeroMetrics.tvHeroHeightFraction`.
        // `containerRelativeFrame(.vertical)` measures the enclosing ScrollView's height, which
        // the sidebar collapse doesn't change, so the band height stays put and the focused
        // controls never get scrolled out of reach.
        content
            .frame(maxWidth: .infinity)
            .containerRelativeFrame(.vertical) { height, _ in height * HeroMetrics.tvHeroHeightFraction }
        #else
        content
            .frame(maxWidth: .infinity)
            .aspectRatio(HeroMetrics.bandAspectRatio(regularWidth: regularWidth), contentMode: .fit)
        #endif
    }
}

extension View {
    func heroBandFrame(regularWidth: Bool) -> some View {
        modifier(HeroBandFrame(regularWidth: regularWidth))
    }
}

// MARK: - Foreground legibility (HIG: background layer, not stacked text shadows)

/// Scrim ramp math and the shipping wash recipes, kept off the view so `AppLayoutTests`
/// can pin both the curve and the recipe invariants.
enum HeroScrim {
    /// One shared smoothstep ramp: `(location, eased)` pairs spanning `from`…1. Both stop
    /// builders map over this, so the curve, step count, and location math can never
    /// drift between the washes and their taper masks.
    private static func easedRamp(from: Double, steps: Int) -> [(location: Double, eased: Double)] {
        (0...steps).map { i in
            let t = Double(i) / Double(steps)
            return (from + (1 - from) * t, t * t * (3 - 2 * t))   // smoothstep
        }
    }

    /// Smoothstep-eased gradient stops: fully clear through `from` (a 0…1 fraction of the
    /// gradient axis), then easing to `maxOpacity` black at the far edge. The interpolated
    /// curve is the point — a 2-3 hard-stop gradient paints a visible onset line across
    /// bright artwork (the "shadow edge" the old scrims had), while an eased ramp has no
    /// derivative jump anywhere, so there is no line to see.
    static func easedStops(from: Double, maxOpacity: Double, steps: Int = 8) -> [Gradient.Stop] {
        [.init(color: .black.opacity(0), location: 0)]
            + easedRamp(from: from, steps: steps).map {
                .init(color: .black.opacity(maxOpacity * $0.eased), location: $0.location)
            }
    }

    /// Mask stops that TAPER a wash along its other axis: full strength (opaque white)
    /// through `from`, easing down to `minimum` strength at the far edge. Used to relax a
    /// stroke away from the foreground corner without cutting it off — a hard stop would
    /// re-introduce the visible edge the eased ramps exist to avoid.
    static func easedMaskStops(from: Double, minimum: Double, steps: Int = 8) -> [Gradient.Stop] {
        [.init(color: .white, location: 0)]
            + easedRamp(from: from, steps: steps).map {
                .init(color: .white.opacity(1 - (1 - minimum) * $0.eased), location: $0.location)
            }
    }

    // MARK: Shipping recipes (cached — the carousel re-evaluates every scroll frame)

    static let compactBottom = easedStops(from: 0.36, maxOpacity: 0.78)
    static let regularBottom = easedStops(from: 0.44, maxOpacity: 0.72)
    /// Corner-biased: the higher max compensates the tapers right where the title/logo
    /// sit (the wash peaks at the leading edge), without re-extending either reach.
    static let regularLeading = easedStops(from: 0.55, maxOpacity: 0.60)
    /// Bottom stroke taper: full strength under the foreground column, easing to 55% by
    /// the trailing edge (the dots at bottom-center still sit on ~85%).
    static let bottomTaper = easedMaskStops(from: 0.40, minimum: 0.55)
    /// Leading stroke taper: full strength beside the foreground, easing to 50% at the
    /// band top. NEVER let this reach zero — the leading column is what the sidebar
    /// extension effect mirrors; a clear top re-brightens the strip and brings the
    /// boundary seam back.
    static let leadingTaper = easedMaskStops(from: 0.45, minimum: 0.50)
}

/// Legibility washes over the hero artwork, behind the foreground column. Full-band
/// gradients sized by stop fractions, so the view needs no band geometry at all:
///  • every idiom gets a bottom wash (title/overview/actions live in the bottom third);
///  • the landscape band (iPad/tvOS) adds a leading wash — its foreground hugs the
///    bottom-LEADING corner, and the two washes compound there (Apple-TV-style corner
///    weighting) without the elliptical smudge the old oval scrim painted.
///
/// Both landscape strokes are TAPERED away from that corner (eased masks, never hard
/// cuts): the bottom wash relaxes toward the trailing edge and the leading wash relaxes
/// toward the top, hugging the actual foreground size. The leading wash deliberately
/// keeps ~half strength at the very top — its leading column is what the sidebar
/// `backgroundExtensionEffect` mirrors, so dropping it to zero up there would re-brighten
/// the mirrored strip and bring the boundary seam back above the wash line.
struct HeroBandScrim: View {
    let regularWidth: Bool

    var body: some View {
        ZStack {
            if regularWidth {
                LinearGradient(stops: HeroScrim.regularBottom, startPoint: .top, endPoint: .bottom)
                    .mask(
                        LinearGradient(stops: HeroScrim.bottomTaper, startPoint: .leading, endPoint: .trailing)
                    )
                LinearGradient(stops: HeroScrim.regularLeading, startPoint: .trailing, endPoint: .leading)
                    .mask(
                        LinearGradient(stops: HeroScrim.leadingTaper, startPoint: .bottom, endPoint: .top)
                    )
            } else {
                LinearGradient(stops: HeroScrim.compactBottom, startPoint: .top, endPoint: .bottom)
            }
        }
        .allowsHitTesting(false)
    }
}

extension View {
    /// Hero artwork composite: the legibility scrim layered over the content, then the iPad
    /// sidebar `backgroundExtensionEffect` over BOTH. The ordering is the load-bearing part:
    /// the effect mirrors the view it is attached to, so a scrim layered as a sibling ABOVE
    /// it darkens only the real artwork and leaves the mirrored strip raw-bright — a hard
    /// luminance jump at the sidebar boundary, and the brightest possible stage for the
    /// system's edge rim. Routing every hero through this modifier makes the ordering
    /// structural instead of a per-call-site convention.
    func heroScrimmedExtension(regularWidth: Bool) -> some View {
        ZStack {
            self
            HeroBandScrim(regularWidth: regularWidth)
        }
        .tvPlatformGated { $0.backgroundExtensionEffect(isEnabled: regularWidth) }
    }

    /// The iPad sidebar bleed, WITHOUT a scrim — `backgroundExtensionEffect` mirrors the hero
    /// artwork's leading strip under the floating sidebar. Legibility now lives on the foreground
    /// (`HeroBottomFade` / `HeroCornerFade`), so the artwork stays clean. Trade-off: the mirrored
    /// strip is now raw artwork, so the documented `ipad-sidebar-pane-rim` seam can resurface over
    /// bright art — re-add a faint leading seam-guard wash here (reusing `HeroScrim`) if it does.
    /// tvOS/iPhone: no-op.
    func heroBandExtension(regularWidth: Bool) -> some View {
        tvPlatformGated { $0.backgroundExtensionEffect(isEnabled: regularWidth) }
    }
}

// MARK: - Preview harness

// iPad-only diagnostic (sidebarAdaptable + sidebar bottom bar don't exist on
// tvOS); without the guard this preview alone breaks the whole tvOS build.
#if !os(tvOS)
#Preview("HeroBand · sidebar bleed") {
    TabView {
        Tab("Home", systemImage: "house") {
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: Space.s30) {
                        HeroBand {
                            LinearGradient(
                                colors: [Color(red: 0.42, green: 0.20, blue: 0.55),
                                         Color(red: 0.0, green: 0.40, blue: 0.74)],
                                startPoint: .topLeading, endPoint: .bottomTrailing
                            )
                            .heroScrimmedExtension(regularWidth: true)
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
                        .heroBandFrame(regularWidth: true)
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
        // Mirror RootTabView's floating-sidebar ingredients: a TabSection + bottom
        // bar switch sidebarAdaptable into the floating-card presentation the app
        // actually ships — the plain-tab pane style draws DIFFERENT edge chrome.
        TabSection("Libraries") {
            Tab("Movies", systemImage: "film") { Color.background }
        }
    }
    .tabViewStyle(.sidebarAdaptable)
    .tabViewSidebarBottomBar {
        Label("Settings", systemImage: "gearshape").font(.footnote)
    }
    // The key default is .compact — without this the preview silently renders the
    // COMPACT band with backgroundExtensionEffect(isEnabled: false), which is not
    // what ships on iPad (and cost a whole seam investigation a false acquittal).
    .environment(\.appIdiom, .regular)
}
#endif


/// Worst-case artwork for scrim verification: near-white sky with bright high-frequency
/// detail in the bottom-leading corner — exactly where the foreground column sits. If the
/// washes hold here, they hold on any real backdrop.
private struct WorstCaseArtwork: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(white: 0.92), Color(white: 0.99), Color(white: 0.96)],
                startPoint: .top, endPoint: .bottom
            )
            Canvas { context, size in
                // Deterministic bright clutter (no randomness — renders must be reproducible).
                for i in 0..<60 {
                    let fi = Double(i)
                    let x = (fi * 137.5).truncatingRemainder(dividingBy: 360) / 360 * size.width
                    let y = size.height * (0.45 + (fi * 61.8).truncatingRemainder(dividingBy: 180) / 180 * 0.55)
                    let r = 6 + (fi * 13.7).truncatingRemainder(dividingBy: 22)
                    let rect = CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)
                    context.fill(
                        Path(ellipseIn: rect),
                        with: .color(i.isMultiple(of: 2) ? .white : Color(white: 0.78))
                    )
                }
            }
        }
    }
}

/// Shared fake foreground for the legibility previews — mirrors the REAL `HeroForeground`: eyebrow,
/// heavy title, the height-adaptive `AdaptiveHeroOverview`, the 46pt Play pill, the
/// `foregroundMaxHeight` cap, and the fixed-size rows. So the render exhibits the actual flex (the
/// overview trims its line count to the cap) without needing a `Session` for a real `HeroTitle`.
private struct PreviewHeroForeground: View {
    let regularWidth: Bool

    @Environment(\.appIdiom) private var idiom

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s12) {
            Text("FEATURED")
                .font(.caption.weight(.bold)).tracking(1.5)
                .foregroundStyle(.white)
                .padding(.horizontal, Space.s12).padding(.vertical, Space.s3)
                .background(.black.opacity(0.5), in: Capsule())
                .fixedSize(horizontal: false, vertical: true)
            Text("Orbital")
                .scaledFont(regularWidth ? 52 : 32, relativeTo: .largeTitle, weight: .heavy)
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
            AdaptiveHeroOverview(
                text: "A crew on humanity's last orbital station races to prevent a cascade failure before re-entry, rationing oxygen while the ground crew fights to reach them in time.",
                regularWidth: regularWidth
            )
            Label("Play", systemImage: "play.fill")
                .font(.headline).foregroundStyle(Color.buttonLabel)
                .padding(.horizontal, Space.s22).frame(height: 46)
                .background(Color.buttonFill, in: Capsule())
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, Space.s8)
        }
        .frame(maxHeight: HeroMetrics.foregroundMaxHeight(idiom: idiom), alignment: .bottom)
    }
}

/// Permanent diagnostic: white text over deliberately hostile bright artwork, both band
/// variants. Verify with `RenderPreview` + pixel sampling behind the text column (target:
/// large heavy title ≥3:1, subheadline overview as close to 4.5:1 as the wash allows).
// `.fixedLayout` so the canvas IS the band size — otherwise a wide iPad band rendered on an
// iPhone destination overflows and clips to the center, hiding the bottom-leading panel.
#Preview("Hero legibility · panel (regular)", traits: .fixedLayout(width: 1024, height: 576)) {
    HeroBand {
        WorstCaseArtwork()
    } foreground: {
        PreviewHeroForeground(regularWidth: true)
    }
    .heroBandFrame(regularWidth: true)
    .environment(\.appIdiom, .regular)
}

#Preview("Hero legibility · fade (compact)", traits: .fixedLayout(width: 420, height: 630)) {
    HeroBand {
        WorstCaseArtwork()
    } foreground: {
        PreviewHeroForeground(regularWidth: false)
    }
    .heroBandFrame(regularWidth: false)
}
