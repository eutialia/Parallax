import SwiftUI
import ParallaxJellyfin
import ParallaxCore

/// The Apple-TV / Infuse-style hero band — the single container behind BOTH the Home carousel
/// and the movie/series detail header. It is a dumb two-slot stacker and nothing more: it stacks
/// an `artwork` layer under a `foreground` column (bottom-leading), turns hits off on the artwork,
/// and places the column in the readable region. It owns the legibility treatment (an idiom-split
/// frosted fade) AND the iPad sidebar extension; the rest is delegated, because the band's effects
/// don't all live at the same layer:
///
///  • **Legibility** (`HeroBottomFade` compact / `HeroCornerFade` landscape) sits BETWEEN the
///    artwork and the foreground, inserted here so all three call sites share one treatment, and
///    composited WITH the artwork into the layer that carries the sidebar extension (below) — so
///    the `backgroundExtensionEffect` reflection mirrors artwork AND veil together and the mirrored
///    sidebar strip darkens in lockstep with the main side (no luminance seam at the boundary).
///  • **Artwork-bound transforms** (bottom clip, parallax offset) ride the `artwork` slot: the
///    parallax moves the image while the legibility veil + title/actions stay put — that
///    differential IS the parallax. The caller bakes them into whatever it hands the slot (a plain
///    `HeroBandImage` on detail; the parallaxed `CrossfadeArtwork` on Home).
///  • **Sidebar extension** (`heroBandExtension`, iPad-only) is owned HERE, wrapping the
///    artwork+legibility composite so the mirror carries the veil. The foreground column stays
///    OUTSIDE it (Apple's Landmarks rule: extend the artwork under the sidebar, never the title).
///  • **Pull-down stretch** (`scroll:`, Home-only) is owned HERE too, and MUST wrap the composite
///    one layer OUTSIDE the sidebar extension: `backgroundExtensionEffect` clips its content to
///    bounds (documented — "will clip the view to prevent copies from overlapping"), so a stretch
///    applied inside the `artwork` slot gets its upward overpaint amputated on iPad and the
///    rubber-band gap shows the app background above the band. That exact exposure shipped twice
///    (pre-4be53be: no stretch at all; 56bae0b: extension moved outside the slot's stretch), which
///    is why the ordering is now structural instead of a call-site convention. Regression check:
///    the "pull-down stretch" previews below — magenta above the artwork means it's back.
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
/// can remove it. This 1-2px system hairline is DISTINCT from the wide luminance seam the legibility
/// veil used to cause (raw-bright mirror beside a darkened main side); compositing the veil into the
/// extension-sampled layer (see body) fixes that one. Details: memory `ipad-sidebar-pane-rim`.
struct HeroBand<Artwork: View, Foreground: View>: View {
    /// Scroll channel driving the pull-down stretch zoom (Home passes its `HeroScrollState`;
    /// the detail headers pass nothing — their band doesn't stretch). The same state also
    /// drives the parallax, but that lives inside the `artwork` slot: the veil must NOT lag
    /// with the artwork, while the stretch scales artwork AND veil together.
    var scroll: HeroScrollState? = nil
    @ViewBuilder var artwork: () -> Artwork
    @ViewBuilder var foreground: () -> Foreground

    @Environment(\.appIdiom) private var idiom

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            // Artwork + legibility composited as ONE layer that carries the iPad sidebar extension,
            // so `backgroundExtensionEffect` mirrors the artwork AND the legibility veil under the
            // sidebar — the mirrored strip darkens in lockstep with the main side, instead of
            // reflecting raw-bright artwork while the veil darkens only the main side (the old hard
            // left/right luminance seam at the sidebar boundary). The veil still stays put relative
            // to the parallaxing artwork: the artwork transforms inside its own slot (Home's
            // `HeroScrollArtwork`) and the veil layers over that result here, so the parallax
            // differential is unchanged. The tall poster band gets a full-width bottom fade; the
            // wide landscape band gets a corner-focused glow so the darkening sits on the bottom-
            // leading text, not the empty right side.
            HeroStretchLayer(
                scroll: scroll,
                content: ZStack(alignment: .bottomLeading) {
                    artwork()
                    if idiom == .compact {
                        HeroBottomFade()
                    } else {
                        HeroCornerFade()
                    }
                }
                .heroBandExtension(regularWidth: idiom.usesLandscapeHeroBand)
            )
            .allowsHitTesting(false)
            // Foreground (title/actions) stays OUTSIDE the extension — Apple's Landmarks rule:
            // extend the artwork under the sidebar, never the title/buttons.
            foreground()
                .heroForegroundPlacement(idiom: idiom)
        }
    }
}

/// Reference-type carrier for the hero's per-frame scroll adjustment. An `@Observable` class
/// (rather than a value passed down the view tree) so a scroll write invalidates only the views
/// that READ `adjustment` — `HeroStretchLayer` and Home's `HeroScrollArtwork` — leaving the
/// screen's body and the band's foreground (title, actions, page dots) untouched on a scroll frame.
@Observable
@MainActor
final class HeroScrollState {
    /// Signed scroll adjustment (pt): positive = pull-down rubber-band (stretch zoom),
    /// negative = scrolled into the feed (parallax lag), 0 at rest. The two effects are
    /// mutually exclusive by sign.
    var adjustment: CGFloat

    init(adjustment: CGFloat = 0) {
        self.adjustment = adjustment
    }
}

/// Applies the pull-down stretch zoom to the band's artwork+veil+extension composite. Two
/// load-bearing placement rules, both regression-tested by the "pull-down stretch" previews:
///
///  1. OUTSIDE `heroBandExtension`: `backgroundExtensionEffect` clips its content to bounds, so
///     any transform that must paint past the band — the stretch's upward overpaint that covers
///     the rubber-band gap — has to sit outside it, or the gap exposes the app background
///     (the twice-shipped bug; last via 56bae0b).
///  2. Render-only (`visualEffect`, which also supplies the band height): the stretch must never
///     feed scroll geometry back into layout — that loop opened the gap-that-snaps-shut of the
///     June '26 offset-math hero (f4b64b3).
///
/// `adjustment` is read HERE, not in `HeroBand.body`, and `content` is a stored value — so a
/// per-frame scroll write re-evaluates only this wrapper and re-renders the composite, without
/// rebuilding the artwork/foreground view trees.
private struct HeroStretchLayer<Content: View>: View {
    let scroll: HeroScrollState?
    let content: Content

    var body: some View {
        let adjustment = scroll?.adjustment ?? 0
        content.visualEffect { effect, geometry in
            effect.scaleEffect(
                HeroMetrics.stretchScale(forScrollAdjustment: adjustment, bandHeight: geometry.size.height),
                anchor: .bottom
            )
        }
    }
}

/// Shared hero geometry so the Home `HomeHeroCarousel` and the detail `HeroBand` can't
/// drift apart. A plain namespace (not a static on the generic `HeroBand`, which would
/// force callers to spell out its two type parameters just to read a constant).
enum HeroMetrics {
    /// Readable column width for hero foreground content (title, meta, actions). tv widens with
    /// its type ramp — 720 on the 1920pt canvas was the iPad column verbatim (the audit's C1/C3
    /// "tv sized like iPad" defect class, which missed the hero).
    static func contentMaxWidth(idiom: AppIdiom) -> CGFloat {
        idiom == .tv ? 1080 : 720
    }
    /// Overview blurb — tighter on iPad so three lines wrap sooner. tv holds iPad's ~32em measure
    /// at the tvOS subheadline size (≈29pt vs 15pt): 480 × 29/15 ≈ 880.
    static func overviewMaxWidth(idiom: AppIdiom) -> CGFloat {
        switch idiom {
        case .compact: contentMaxWidth(idiom: .compact)
        case .regular: 480
        case .tv: 880
        }
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
    /// `nonisolated`: pure math, called from `HeroStretchLayer`'s `@Sendable` render closure.
    nonisolated static func stretchScale(forScrollAdjustment value: CGFloat, bandHeight: CGFloat) -> CGFloat {
        guard bandHeight > 0 else { return 1 }
        return 1 + max(0, value) / bandHeight
    }
    /// tvOS hero height as a fraction of the viewport — the FALLBACK for the first layout pass only.
    /// The band normally fills the true PHYSICAL screen via the measured `\.heroViewportHeight` (see
    /// `HeroBandFrame` + `heroScreenSafeArea`), because `containerRelativeFrame` on its own is
    /// safe-area-bounded and lands an overscan strip short — that shortfall peeked the next row and
    /// read as a hero shifted up off a gap. 1.0 keeps the one-frame fallback as close to the final
    /// full-screen height as possible (minimal settle), and at full height the 16:9 landscape artwork
    /// fills a 16:9 TV edge-to-edge with no vertical crop. Deliberately NOT width-derived: a
    /// width-derived band grows taller when the `.sidebarAdaptable` menu collapses, shoving the
    /// bottom-anchored controls down and scrolling the band's top off-screen; a constant value holds.
    static let tvHeroHeightFraction: CGFloat = 1.0
    /// On tvOS the full-bleed hero fills the whole viewport, so its bottom-anchored controls must
    /// sit well ABOVE the bottom — not merely past the ~90pt overscan, but far enough that the focus
    /// engine doesn't auto-scroll the whole hero to lift the focused Play/Favorite into the title-safe
    /// zone and reveal "look-ahead" context below them (a control near the bottom edge makes tvOS
    /// scroll the band up, dragging the next shelf in and breaking the full-screen look). Two overscan
    /// insets — the title-safe line plus a full overscan of clearance — parks the controls in the lower
    /// third where Apple's own TV hero sits. iPhone/iPad have no overscan, so they keep the tight inset.
    static func foregroundBottomInset(idiom: AppIdiom) -> CGFloat {
        switch idiom {
        // Compact lifts the column a notch more so the page dots stop crowding the third overview
        // line; regular keeps the tighter inset. tvOS parks the controls well above the overscan.
        case .compact: Space.s40
        case .regular: Space.s30
        case .tv: AppLayout.tvOverscanInset * 2
        }
    }
    /// Bottom inset for the carousel's page dots, measured from the band's bottom edge. compact/regular
    /// tuck them just below the action row (the old iPhone `Space.s3` jammed them against the poster's
    /// bottom seam, reading as "falling out" of the hero into the shelves). tvOS keeps them near the
    /// bottom edge — just clear of the overscan title-safe line — NOT lifted with the controls: the dots
    /// aren't focusable, so they don't trigger the focus-scroll the controls' inset guards against, and a
    /// page indicator reads better at the bottom than floating in the lower third.
    static func pageIndicatorBottomInset(idiom: AppIdiom) -> CGFloat {
        switch idiom {
        case .compact, .regular: Space.s22
        case .tv: AppLayout.tvOverscanInset
        }
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
    #if os(tvOS)
    // Only the tvOS branch reads this; declaring it iOS-side would leave a live env
    // subscription that never feeds layout (the `#else` path is aspect-ratio derived).
    @Environment(\.heroViewportHeight) private var viewportHeight
    #endif

    func body(content: Content) -> some View {
        #if os(tvOS)
        // Fill the WHOLE screen: prefer the measured true screen height (`heroViewportHeight`, from
        // `heroScreenSafeArea()`), which includes the overscan strip that `containerRelativeFrame`'s
        // own safe-area-bounded value omits — that shortfall is what peeked the next row. Fall back
        // to that safe value × the fraction only for the first layout pass, before the measurement
        // lands. A constant height (not width-derived) holds steady across the `.sidebarAdaptable`
        // collapse, so the focused controls never get scrolled out of reach.
        content
            .frame(maxWidth: .infinity)
            .containerRelativeFrame(.vertical) { containerHeight, _ in
                viewportHeight > 0 ? viewportHeight : containerHeight * HeroMetrics.tvHeroHeightFraction
            }
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

// MARK: - Sidebar extension

extension View {
    /// The iPad sidebar bleed: `backgroundExtensionEffect` mirrors the band's leading strip (flipped
    /// + blurred) under the floating sidebar. `HeroBand` applies this to the artwork+legibility
    /// COMPOSITE — not raw artwork — so the mirrored strip carries the same legibility veil as the
    /// main side and the two meet without a luminance seam at the boundary. The residual
    /// `ipad-sidebar-pane-rim` hairline is unrelated system region-edge chrome. tvOS/iPhone: no-op.
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
                            // Raw artwork only — HeroBand now owns `heroBandExtension`, applied to
                            // the artwork+legibility composite so the mirror carries the veil.
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
                                    text: "A crew on humanity's last orbital station races to prevent a cascade failure."
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

// Seam diagnostic that works on ANY destination (no iPad sim required): a manual leading
// `.safeAreaInset` stands in for the floating sidebar's safe-area inset — the region the leading
// `backgroundExtensionEffect` mirrors into — over the bright `WorstCaseArtwork` (toughest case for
// the boundary seam). Watch the inset↔hero boundary: the mirrored strip should darken with the same
// `HeroCornerFade` veil as the main side, NOT show raw-bright reflection beside a darkened main side.
#Preview("HeroBand · sidebar seam (simulated inset)", traits: .fixedLayout(width: 980, height: 560)) {
    ScrollView {
        VStack(alignment: .leading, spacing: Space.s30) {
            HeroBand {
                WorstCaseArtwork()
            } foreground: {
                PreviewHeroForeground(regularWidth: true)
            }
            .heroBandFrame(regularWidth: true)
            Rectangle().fill(Color.fill).frame(height: 120).padding(.horizontal, Space.s40)
        }
    }
    .scrollClipDisabled(true)
    .background(Color.background)
    .ignoresSafeArea(edges: .top)
    .safeAreaInset(edge: .leading, spacing: 0) {
        // Stand-in for the floating sidebar: a fixed-width leading inset the band extends under.
        Color.gray.opacity(0.25).frame(width: 150).ignoresSafeArea()
    }
    .environment(\.appIdiom, .regular)
}
#endif


/// Permanent regression diagnostic for the pull-down stretch — the twice-shipped "background
/// exposed above the hero" bug. A frozen mid-pull frame: the band has travelled down 120pt with
/// the rubber-band (`offset`) and `scroll.adjustment` carries the same 120, exactly the state
/// mid-gesture. The magenta floor stands in for `Color.background`: ANY magenta above the
/// artwork's top edge = the regression (something between the stretch and the screen is clipping
/// the overpaint — in 56bae0b it was `backgroundExtensionEffect`, which clips to bounds).
/// Regular is the case that regressed: the extension only engages on iPad.
#Preview("HeroBand · pull-down stretch (regular)", traits: .fixedLayout(width: 900, height: 660)) {
    ZStack(alignment: .top) {
        Color(red: 1, green: 0, blue: 0.6).ignoresSafeArea()
        HeroBand(scroll: HeroScrollState(adjustment: 120)) {
            LinearGradient(
                colors: [Color(red: 0.10, green: 0.16, blue: 0.36),
                         Color(red: 0.02, green: 0.36, blue: 0.44)],
                startPoint: .top, endPoint: .bottom
            )
        } foreground: {
            PreviewHeroForeground(regularWidth: true)
        }
        .heroBandFrame(regularWidth: true)
        .offset(y: 120)
    }
    .environment(\.appIdiom, .regular)
}

#Preview("HeroBand · pull-down stretch (compact)", traits: .fixedLayout(width: 393, height: 720)) {
    ZStack(alignment: .top) {
        Color(red: 1, green: 0, blue: 0.6).ignoresSafeArea()
        HeroBand(scroll: HeroScrollState(adjustment: 120)) {
            LinearGradient(
                colors: [Color(red: 0.10, green: 0.16, blue: 0.36),
                         Color(red: 0.02, green: 0.36, blue: 0.44)],
                startPoint: .top, endPoint: .bottom
            )
        } foreground: {
            PreviewHeroForeground(regularWidth: false)
        }
        .heroBandFrame(regularWidth: false)
        .offset(y: 120)
    }
}

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
                text: "A crew on humanity's last orbital station races to prevent a cascade failure before re-entry, rationing oxygen while the ground crew fights to reach them in time."
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
