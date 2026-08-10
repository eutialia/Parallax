import SwiftUI
import ParallaxJellyfin
import ParallaxCore

/// The Apple-TV / Infuse-style hero — the band behind BOTH the Home carousel and the movie/series
/// detail header. On iPhone/iPad it ships as TWO PAIRED PIECES that sit on opposite sides of the
/// scroll view; on tvOS it stays one in-scroll stack.
///
///  • `HeroBackdrop` — the PICTURE (artwork + bottom treatments + contact shadow). Mounted as the
///    hero screen's BACKGROUND, behind the scroll view and outside its content, pinned to the top.
///  • `HeroBand` — the in-scroll half. iPhone/iPad: a transparent, band-tall spacer carrying the
///    foreground column and the floor bleed. tvOS: the whole band, picture included.
///
/// WHY THE PICTURE LEFT THE SCROLL CONTENT
///
/// On iPad the picture has to reach under the floating sidebar, and the system
/// `backgroundExtensionEffect` is what puts it there: it mirrors and blurs whatever content falls
/// outside the safe area. That mirror is a LIVE lens — transform the content INSIDE the effect and
/// the mirror re-samples the transformed pixels on the same frame (measured on device-class
/// hardware: a 60pt shift inside the effect slides the mirrored colours by exactly 60pt, and a
/// 1.35× scale zooms them, staying colour-continuous across the boundary). Live sampling is the
/// whole value of the effect, and it is also the whole constraint:
///
///  • A transform INSIDE the effect is re-sampled → mirror and artwork move together and the seam
///    between them holds.
///  • A transform OUTSIDE the effect moves the finished composite — mirror and artwork as one flat
///    bitmap — so the seam slides off the band's leading edge and opens. That failure drove a
///    whole DIY mirrored-strip detour (since deleted) before the architecture settled here, and
///    it is why nothing may wrap the effect's output in anything but a RIGID TRANSLATION (a
///    translation moves the seam and the content by the same amount, so it can't open).
///
/// The pull-down stretch is a SCALE, so it must live inside the effect. A band hosted in the
/// scroll content can't have that: the rubber-band already moves the band's frame, so the stretch
/// has to compensate for its own host's travel, and every arrangement that worked put the scale
/// outside. Pinning the picture OUTSIDE the scroll view removes the host travel entirely — the
/// frame is static, the scale goes inside, and the only thing left outside is a rigid translation.
///
/// WHY THE FOREGROUND STAYED IN THE CONTENT
///
/// The title/actions column must stay tappable and must scroll with the page, and Apple's Landmarks
/// rule keeps it OUT of the extended region regardless (extend the artwork under the sidebar, never
/// the title). So it rides a transparent band-tall spacer at the top of the scroll column, bottom-
/// aligned, on the same `heroForegroundPlacement` insets as before. The floor bleed hangs off that
/// spacer's bottom edge for the same reason plus one more: `HeroFloorBleed` pauses its animation via
/// `onScrollVisibilityChange`, which only ever fires inside a scroll view.
///
/// WHY THE TOP GAP CANNOT COME BACK
///
/// "App background exposed above the hero on pull-down" shipped twice (first with no stretch at
/// all, then when the stretch landed inside a bounds-clipping effect). Both were the same shape —
/// the band travelled DOWN with the rubber-band and something had to paint back up over the gap.
/// The backdrop no longer travels: its frame is pinned to the screen top and the pull-down scale is
/// anchored `.top`, so the top edge is a fixed line and there is no gap to overpaint. The
/// "pinned top mid-pull" preview below is the standing guard.
///
/// The effect CLIPS its content to its own bounds (measured: a 1.35× top-anchored scale inside the
/// effect stops painting at the host frame's bottom, while the same scale with the effect off runs
/// on to 1.35× the height). So the host frame GROWS with the pull instead — see
/// `HeroBackdropPicture`. That growth is a frame change, not a render transform, but it is safe
/// here precisely because the backdrop is not in the scroll content: nothing it does can feed back
/// into scroll geometry, which is the loop that killed the June '26 offset-math hero.
///
/// Sizing stays a call-site concern (`heroBandFrame`), and the backdrop derives the same height
/// from its own width so the two halves can't drift.
///
/// Parent `ScrollView`s use `.ignoresSafeArea(edges: .top)` (via `heroScreenSafeArea`): that drops
/// the top content inset so the spacer starts at y=0 and the backdrop paints under the status bar.
/// iPhone uses a 2:3 poster band; iPad/tvOS use 16:9 landscape.
///
/// SIDEBAR SEAM: a 1-2px hairline at the region edge is SYSTEM chrome (pixel-bisected +
/// control-rendered 2026-06-11; do not re-investigate) — full window height, composited above all
/// app content, present with the extension effect disabled, on the loading skeleton, and in a
/// `NavigationSplitView` control render, so no app-side layer can remove it. Details: memory
/// `ipad-sidebar-pane-rim`.
struct HeroBand<Artwork: View, Foreground: View>: View {
    /// Scroll channel. On tvOS it drives the in-scroll stretch; on iPhone/iPad the picture's motion
    /// belongs to `HeroBackdrop`, so this slot ignores it. nil = a static band.
    var scroll: HeroScrollState? = nil
    /// BlurHash of the artwork the band is currently showing. Drives the floor bleed — the item's
    /// decoded blur spilling below the band's bottom edge into the page (`HeroFloorBleed`). The
    /// caller owns WHICH image is displayed (idiom pick, carousel page), so it supplies the hash;
    /// nil = no bleed, the artwork just ends at its hard edge.
    var floorBleedHash: String? = nil
    /// The picture. **tvOS only** — on iPhone/iPad the picture is mounted by the paired
    /// `HeroBackdrop` behind the scroll view and this slot never builds it. Bind it to a local
    /// `let` at the call site and hand the SAME value to both, so the two halves can't drift.
    @ViewBuilder var artwork: () -> Artwork
    @ViewBuilder var foreground: () -> Foreground

    @Environment(\.appIdiom) private var idiom

    var body: some View {
        #if os(tvOS)
        // tvOS keeps the original one-piece band: no floating sidebar to reach under, no
        // `backgroundExtensionEffect` in the SDK, and a full-viewport focus-scrolled hero that
        // wants to travel with its content.
        ZStack(alignment: .bottomLeading) {
            HeroStretchLayer(
                scroll: scroll,
                content: HeroComposite(scroll: scroll, artwork: artwork)
            )
            .allowsHitTesting(false)
            foreground()
                .heroForegroundPlacement(idiom: idiom)
        }
        .heroFloorBleed(hash: floorBleedHash, idiom: idiom)
        #else
        // iPhone/iPad: a transparent stand-in for the picture, so the foreground column keeps its
        // exact placement (bottom-aligned in a band-tall box) and the page below starts at the
        // band's bottom edge — while the picture itself stays out of the scroll content entirely.
        // Sized by the caller's `heroBandFrame`, same as the tvOS branch: one framing rule for both
        // platforms, and the same aspect ratio the paired `HeroBackdrop` derives its own height
        // from, so spacer and picture land on the same number.
        Color.clear
            .overlay(alignment: .bottomLeading) {
                foreground()
                    .heroForegroundPlacement(idiom: idiom)
            }
            .heroFloorBleed(hash: floorBleedHash, idiom: idiom)
        #endif
    }
}

// MARK: - Backdrop (iPhone / iPad)

#if !os(tvOS)
/// The hero's PICTURE, mounted behind the scroll view — pair it with the `HeroBand` slot that
/// carries the same screen's foreground:
///
/// ```swift
/// let art = HeroBandImage(…)              // build the artwork ONCE
/// ScrollView {
///     HeroBand(artwork: { art }) { … }    // spacer + foreground
///     pageContent
/// }
/// .heroBackdrop(scroll: heroScroll, artwork: art)   // this view, mounted as a background
/// .heroScreenSafeArea()
/// .screenFloor()
/// ```
///
/// Mounted as a `.background` rather than a root `ZStack` on purpose: that puts the picture
/// directly behind the scroll content but still in FRONT of `screenFloor()`, so the floor keeps its
/// screen-sized, screen-pinned elliptical field instead of becoming a content-sized gradient that
/// scrolls with the page.
///
/// The backdrop paints exactly its own rect and travels with the feed, so once the page has
/// scrolled past it there is nothing left behind the content to show through — no page-side
/// occluder is needed.
struct HeroBackdrop<Artwork: View>: View {
    /// Drives BOTH scroll effects, at their two different layers — see `HeroBackdropPicture`.
    /// nil = a static picture (previews, any future scroll-less host).
    var scroll: HeroScrollState? = nil
    @ViewBuilder var artwork: () -> Artwork

    @Environment(\.appIdiom) private var idiom

    var body: some View {
        // The reader supplies the band's WIDTH; the height follows from the platform aspect ratio,
        // exactly as `heroBandFrame` derives it for the in-scroll spacer, so the two halves land on
        // the same number without measuring each other. Reading geometry here (and not in
        // `HeroBackdropPicture`) keeps the per-frame scroll reader below this closure: a scroll
        // write must not re-run the artwork builder.
        GeometryReader { proxy in
            HeroBackdropPicture(
                scroll: scroll,
                bandHeight: HeroMetrics.bandHeight(
                    forWidth: proxy.size.width,
                    regularWidth: idiom.usesLandscapeHeroBand
                ),
                extendsUnderSidebar: idiom.usesLandscapeHeroBand,
                // The bare picture, no treatments: the effect must sample ONLY artwork (any
                // treatment gradient in the sampled raster doubles into the mirror). The
                // treatments ride ABOVE the effect in `HeroBackdropPicture`.
                content: HeroArtworkLayer(scroll: scroll, artwork: artwork)
            )
        }
        // The picture is decoration; every hit belongs to the scroll content in front of it.
        .allowsHitTesting(false)
    }
}

/// Where the hero's whole kinematic story lives. `adjustment` is read HERE and `content` is a
/// stored value, so a per-frame scroll write re-evaluates only this wrapper — it re-transforms the
/// stored subtree without rebuilding the artwork (the insulation that once required Home's
/// dedicated artwork-wrapper split; without it iOS reloaded the hero's images every scrolled frame).
///
/// The two sides are mutually exclusive by the sign of `adjustment` and continuous at 0:
///
///  • PULL-DOWN (`adjustment > 0`) — INSIDE the effect. A uniform `scaleEffect(anchor: .top)` of
///    `(bandHeight + adjustment) / bandHeight`: the top edge is the anchor, so it stays welded to
///    the pinned frame top, and the bottom edge lands exactly `adjustment` lower — tracking the
///    scroll content, which the rubber-band has moved down by the same amount. The horizontal
///    growth overflows the band's sides and the effect clips it; on the leading side that clip IS
///    the sidebar boundary, and the mirror converges into it from the other direction. Don't fight
///    it. The host frame grows by the same `adjustment` because the effect clips its content to its
///    own bounds — without the growth the picture would be guillotined at the resting height while
///    the page kept travelling.
///  • FEED SCROLL (`adjustment < 0`) — OUTSIDE the effect. A rigid `offset(y:)` of the whole
///    finished composite, which is the one transform that can't open the mirror↔artwork seam.
///    Inside, `HeroParallaxArtwork` still lags the artwork at half speed, so the net picture motion
///    is the same recessed half-speed travel as before.
private struct HeroBackdropPicture<Content: View>: View {
    let scroll: HeroScrollState?
    let bandHeight: CGFloat
    let extendsUnderSidebar: Bool
    let content: Content

    var body: some View {
        let adjustment = scroll?.adjustment ?? 0
        content
            .frame(height: bandHeight)
            .scaleEffect(
                HeroMetrics.stretchScale(forScrollAdjustment: adjustment, bandHeight: bandHeight),
                anchor: .top
            )
            // Grow the effect's bounds with the pull — see the pull-down note above.
            .frame(height: bandHeight + max(0, adjustment), alignment: .top)
            // EDGE OVERSCAN — the resting-white-line fix (lab-bisected on device, 2026-08-10, with
            // a real backdrop: Apple's recipe applied to a bare `Image` is seam-free, the SAME
            // image behind any wrapper mount shows a hairline at the mirror boundary; every layer
            // above was exonerated). When the effect samples a wrapped composite, the composite's
            // own antialiased leading-edge column is part of the raster the mirror reflects — two
            // half-covered columns meet at the seam, and the mirror's blur reads a neighborhood,
            // not just the outermost column (2pt weakened the line on device; 8pt killed it).
            // Scaling the picture past the effect's bounds pushes every edge column (image edge,
            // `MediaImage`/`HeroArtwork` clips, placeholder edge) outside, where the effect's clip
            // discards it, so the mirror samples fully-covered interior pixels. UNIFORM, so all
            // four edges trim and the image keeps its aspect (the first cut was x-only and
            // stretched the picture ~1.5% horizontally); ~1.5% is invisible, the pinned top and
            // the veil's tracking are clip-edge geometry and stay exact.
            .scaleEffect(
                extendsUnderSidebar ? HeroMetrics.edgeOverscanScale(bandHeight: bandHeight) : 1,
                anchor: .center
            )
            .heroBandExtension(regularWidth: extendsUnderSidebar)
            // Bottom treatments + contact shadow, ABOVE the effect — never sampled, never
            // mirrored. On the grown frame, so the bottom-anchored treatments track the pulled
            // bottom edge, and deliberately NOT under the stretch scale: they are a fixed lens
            // protecting a title that barely moves, and scaling them would stretch their gradients.
            .overlay {
                HeroVeilOverlay(extendsUnderSidebar: extendsUnderSidebar)
            }
            // The ONLY thing outside the effect, and rigid by construction. The veil overlay rides
            // it too, staying welded to the band on the way out.
            .offset(y: min(0, adjustment))
            // Pin the band to the top of the reader's box; the rest of the screen is the page's.
            .frame(maxHeight: .infinity, alignment: .top)
    }
}

/// The iPhone/iPad treatment layer, mounted OVER the extension effect: the band-rect treatments
/// (on iPad now just the contact shadow — the wide band carries no veil, see HeroLegibility's
/// header), plus — on iPad — their continuation under the sidebar, so the mirror still darkens in
/// lockstep with the main side at the band's bottom edge without any treatment ever being part of
/// the raster the effect samples.
///
/// The continuation is a clamp-smear: the treatments' leading 1pt column, stretched
/// `veilUnderSidebarReach` wide across the boundary (the negative x factor stretches and places it
/// leading-ward in one transform). Each row continues its boundary value exactly — C0-continuous at
/// the seam with zero horizontal slope, so it cannot crease. A smear of ARTWORK reads as streaks
/// (tried and rejected for the strip); a treatment gradient is a smooth low-frequency field, so its
/// smear is indistinguishable from the "right" continuation, especially under the sidebar's glass.
/// The reach is a fixed overshoot: whatever the sidebar's current width, the surplus paints
/// off-window.
private struct HeroVeilOverlay: View {
    let extendsUnderSidebar: Bool

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            if extendsUnderSidebar {
                HeroVeilTreatments()
                    .clipShape(LeadingSliverRect())
                    .scaleEffect(x: -HeroMetrics.veilUnderSidebarReach, anchor: .leading)
            }
            HeroVeilTreatments()
        }
        .allowsHitTesting(false)
    }
}

/// The veil overlay's 1pt leading column — the smear's source. Open top and bottom so the clip
/// never trims the treatments' own edges.
private struct LeadingSliverRect: Shape {
    func path(in rect: CGRect) -> Path {
        Path(CGRect(x: rect.minX, y: rect.minY - 10_000, width: 1, height: rect.height + 20_000))
    }
}
#endif

// MARK: - Shared pieces

/// Artwork + bottom treatments as ONE opaque layer — the tvOS band's picture. On tvOS the
/// treatments are composited WITH the artwork (no extension effect exists there, so nothing
/// mirrors them) and they stay PUT relative to the parallaxing artwork: the artwork transforms
/// inside its own slot and the treatments layer over that result here, so the parallax
/// differential is unchanged.
///
/// iPhone/iPad deliberately do NOT use this: their picture is `HeroArtworkLayer` ALONE inside the
/// extension effect, with `HeroVeilOverlay` layered ABOVE the effect — the effect must sample
/// nothing but artwork (Apple's Landmarks recipe does the same), and even then the sampled
/// composite needs the edge overscan to keep its own raster edge out of the mirror.
private struct HeroComposite<Artwork: View>: View {
    let scroll: HeroScrollState?
    @ViewBuilder var artwork: () -> Artwork

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            HeroArtworkLayer(scroll: scroll, artwork: artwork)
            HeroVeilTreatments()
        }
        // Flatten before the stretch transforms it: grouped, the treatments composite over the
        // artwork as one opaque picture, so a scale/opacity on the band can't peel the layers.
        .compositingGroup()
    }
}

/// The bare picture — artwork plus its parallax wrapper, and nothing else. What the iPhone/iPad
/// extension effect samples (Landmarks-pure: a mirrored image can only ever show the image's own
/// gradients, never a treatment's), flattened so the effect mirrors a solid picture even
/// mid-crossfade (the carousel stacks two images by opacity).
private struct HeroArtworkLayer<Artwork: View>: View {
    let scroll: HeroScrollState?
    @ViewBuilder var artwork: () -> Artwork

    var body: some View {
        Group {
            if let scroll {
                HeroParallaxArtwork(scroll: scroll, content: artwork())
            } else {
                artwork()
            }
        }
        .compositingGroup()
    }
}

/// The band's bottom treatments, band-rect geometry — shared by the tvOS composite and the
/// iPhone/iPad `HeroVeilOverlay`.
private struct HeroVeilTreatments: View {
    @Environment(\.appIdiom) private var idiom

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            // Compact only: the tall poster band's full-width bottom fade (the text column spans
            // the band there, so the fade reads as its backing). The wide landscape band carries
            // NO veil — bare type on artwork, see HeroLegibility's header.
            if idiom == .compact {
                HeroBottomFade()
            }
            // The page's contact shadow on the artwork — the boundary's depth story (the
            // page surface below stands in FRONT and casts up onto the recessed artwork).
            HeroEdgeShadow()
                // Two frames on purpose: no single `.frame` overload mixes a flexible
                // `maxWidth` with a fixed `height`.
                .frame(maxWidth: .infinity)
                .frame(height: HeroMetrics.edgeShadowHeight(idiom: idiom))
        }
        // Fill the band and do the bottom-pinning HERE: on the wide band the 22pt contact
        // shadow is the stack's ONLY child now (the veil is gone), so without a greedy frame
        // the stack shrinks to the strip — and the alignment-less `.overlay` hosting it then
        // CENTERS the strip in the band, a dark horizontal split mid-artwork (device-caught
        // 2026-08-10). The greedy fill restores what the veil's flexible layer used to provide
        // implicitly.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        .allowsHitTesting(false)
    }
}

/// The artwork slot's scroll-driven half-speed PARALLAX — applied around whatever the `artwork`
/// slot hands over, so every scroll-wired hero parallaxes identically (the recessed artwork lagging
/// the page in front of it — the motion half of the edge-depth story `HeroEdgeShadow` draws).
/// `content` is a stored value on purpose: the per-frame `HeroScrollState.adjustment` writes
/// re-evaluate ONLY this wrapper's body, which re-offsets the stored subtree without rebuilding it.
/// The transform is render-only (offset), so it can't feed scroll geometry back into layout (the
/// trap that killed the June '26 offset-math hero).
/// Reduce Motion and tvOS (focus-driven, full-viewport scroll) both zero the parallax.
///
/// The pull-down stretch deliberately does NOT live here: it belongs to the whole picture
/// (`HeroBackdropPicture` on iOS, `HeroStretchLayer` on tvOS), and this slot is only the artwork
/// inside it.
private struct HeroParallaxArtwork<Content: View>: View {
    let scroll: HeroScrollState
    let content: Content

    @Environment(\.appIdiom) private var idiom
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let parallax = (reduceMotion || idiom == .tv)
            ? 0 : HeroMetrics.parallaxShift(forScrollAdjustment: scroll.adjustment)
        content
            .offset(y: parallax)
            // Bottom-only clip: the lagging artwork must not slide over the content below, but the
            // sides stay open — on iPad the leading edge is what the extension effect mirrors, and
            // a plain `.clipped()` would amputate it.
            .clipShape(BottomBoundedRect())
    }
}

/// A rect open on every side but the bottom — `HeroParallaxArtwork`'s clip. The open sides are the
/// point: a plain `.clipped()` would close all four and cut off the lag or the mirror's source.
private struct BottomBoundedRect: Shape {
    func path(in rect: CGRect) -> Path {
        Path(CGRect(x: rect.minX - 10_000, y: rect.minY - 10_000,
                    width: rect.width + 20_000, height: rect.height + 10_000))
    }
}

#if os(tvOS)
/// tvOS's pull-down stretch: the whole in-scroll composite grows from its bottom edge to fill the
/// rubber-band gap. Render-only (`visualEffect`, which also supplies the band height) — the stretch
/// must never feed scroll geometry back into layout (the offset-math trap). `adjustment` is read
/// HERE and
/// `content` is stored, so a scroll frame re-renders the composite without rebuilding it.
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
#endif

private extension View {
    /// The artwork's light washing down onto the page surface (the page itself stays a seamless
    /// whole — the depth cue is `HeroEdgeShadow`, on the ARTWORK side inside the composite; a
    /// page-side "lip" line shipped briefly and was killed). An overlay hung OUTSIDE the band's
    /// bounds via offset: later siblings in the parent scroll column (shelf titles, the detail
    /// ledger) draw over it, so it reads as ambience behind the page.
    ///
    /// Lives on the IN-SCROLL half on every platform. Besides belonging to the page, `HeroFloorBleed`
    /// pauses its 20fps mesh work through `onScrollVisibilityChange`, which only fires for a view
    /// inside a scroll view — hang it off the backdrop instead and the animation runs forever.
    func heroFloorBleed(hash: String?, idiom: AppIdiom) -> some View {
        let bleed = HeroMetrics.floorBleedHeight(idiom: idiom)
        return overlay(alignment: .bottom) {
            HeroFloorBleed(hash: hash)
                .frame(height: bleed)
                .offset(y: bleed)
        }
    }
}

extension View {
    /// Mounts the hero's PICTURE behind this scroll view — the other half of the `HeroBand` slot
    /// inside it. Apply to the hero-hosting `ScrollView`, BEFORE `heroScreenSafeArea()` (so the
    /// picture inherits the dropped top inset and paints under the status bar) and BEFORE
    /// `screenFloor()` (so the floor stays behind it, screen-sized and screen-pinned).
    ///
    /// Takes the artwork as a VALUE, not a builder: the call site binds it to a local `let` and
    /// hands the same instance to this modifier and to `HeroBand`, which is what stops the two
    /// halves from drifting apart (on tvOS the band renders it; here it does).
    ///
    /// `active` mirrors `heroScreenSafeArea(active:)` for screens whose hero can be absent at
    /// runtime — it gates only the background's CONTENT, never this view's identity, so toggling it
    /// can't tear down the scroll view. tvOS: no-op, its band carries its own picture in-scroll.
    @ViewBuilder
    func heroBackdrop<Artwork: View>(
        active: Bool = true,
        scroll: HeroScrollState?,
        artwork: Artwork
    ) -> some View {
        #if os(tvOS)
        self
        #else
        background(alignment: .top) {
            if active {
                HeroBackdrop(scroll: scroll) { artwork }
            }
        }
        #endif
    }

    /// The iPad sidebar bleed: `backgroundExtensionEffect` mirrors the band's leading strip
    /// (flipped + blurred) under the floating sidebar. Applied to the BARE, edge-overscanned
    /// artwork layer — treatments ride above the effect (`HeroVeilOverlay`), and the overscan
    /// keeps the sampled raster's own edge out of the mirror (the resting-white-line fix). Nothing
    /// outside this may transform the result except a rigid translation (see the file header). The
    /// residual `ipad-sidebar-pane-rim` hairline is unrelated system region-edge chrome. tvOS
    /// lacks the API; iPhone opts out.
    func heroBandExtension(regularWidth: Bool) -> some View {
        tvPlatformGated { $0.backgroundExtensionEffect(isEnabled: regularWidth) }
    }
}

/// Reference-type carrier for the hero's per-frame scroll adjustment. An `@Observable` class
/// (rather than a value passed down the view tree) so a scroll write invalidates only the views
/// that READ `adjustment` — the backdrop's transform wrapper and the artwork parallax — leaving
/// the screen's body and the hero's foreground (title, actions, page dots) untouched on a
/// scroll frame.
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

extension View {
    /// Attach to the hero-hosting `ScrollView`: feeds the SIGNED scroll adjustment into `state` —
    /// positive = pull-down rubber-band (the band's stretchy zoom), negative = scrolled into the
    /// content (the artwork parallax). `contentOffset + contentInsets.top` is 0 at rest regardless
    /// of safe-area/nav-bar insets, so it self-calibrates. The negative side is floored at one
    /// viewport: past that the hero is off-screen, and pinning the value there stops per-frame
    /// state writes (and reader re-evaluations) for the rest of the feed.
    func heroScrollChannel(_ state: HeroScrollState) -> some View {
        onScrollGeometryChange(for: CGFloat.self) { geo in
            max(-(geo.contentOffset.y + geo.contentInsets.top), -geo.containerSize.height)
        } action: { _, newValue in
            state.adjustment = newValue
        }
    }
}

/// Shared hero geometry so the Home `HomeHeroCarousel` and the detail headers can't
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
    /// The band's resting height for a given width — the SAME number `heroBandFrame`'s aspect ratio
    /// produces for the in-scroll spacer. One formula so the fixed backdrop and the spacer that
    /// reserves room for it can never disagree by a point.
    static func bandHeight(forWidth width: CGFloat, regularWidth: Bool) -> CGFloat {
        width / bandAspectRatio(regularWidth: regularWidth)
    }
    /// Half-speed parallax lag for a signed scroll adjustment (positive = pull-down
    /// rubber-band, negative = scrolled into the feed). Only the scrolled-down side
    /// shifts — pull-down belongs to the stretch zoom. The artwork rides at half the
    /// content's speed, the Apple-TV-style hero lag.
    static func parallaxShift(forScrollAdjustment value: CGFloat) -> CGFloat {
        max(0, -value) * 0.5
    }
    /// Stretch-zoom scale for a pull-down rubber-band: the picture grows to fill the gap the
    /// rubber-band opened. Only the positive side scales — the scrolled-down side belongs to
    /// `parallaxShift`; the two effects are mutually exclusive by sign.
    /// `nonisolated`: pure math, also called from tvOS's `@Sendable` render closure.
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
    /// sit well ABOVE the bottom — not merely past the overscan margin, but far enough that the
    /// focus engine doesn't auto-scroll the whole hero to lift the focused Play/Favorite into the
    /// title-safe zone and reveal "look-ahead" context below them (a control near the bottom edge
    /// makes tvOS scroll the band up, dragging the next shelf in and breaking the full-screen
    /// look). The 180pt was tuned against that observed focus behavior on device — an ABSOLUTE,
    /// deliberately not derived from `tvOverscanInset` (a horizontal gutter token whose value
    /// tracks the system inset and can move; this calibration must not move with it). Parks the
    /// controls in the lower third where Apple's own TV hero sits. iPhone/iPad have no overscan,
    /// so they keep the tight inset.
    static func foregroundBottomInset(idiom: AppIdiom) -> CGFloat {
        switch idiom {
        // Compact lifts the column a notch more so the page dots stop crowding the third overview
        // line; regular keeps the tighter inset. tvOS parks the controls well above the overscan.
        case .compact: Space.s40
        case .regular: Space.s30
        case .tv: 180
        }
    }
    /// Bottom inset for the carousel's page dots, measured from the band's bottom edge. compact/regular
    /// tuck them just below the action row (the old iPhone `Space.s3` jammed them against the poster's
    /// bottom seam, reading as "falling out" of the hero into the shelves). tvOS keeps them near the
    /// bottom edge — just clear of the title-safe line — NOT lifted with the controls: the dots
    /// aren't focusable, so they don't trigger the focus-scroll the controls' inset guards against, and a
    /// page indicator reads better at the bottom than floating in the lower third. Absolute for the
    /// same reason as `foregroundBottomInset`: a VERTICAL calibration must not ride the horizontal
    /// `tvOverscanInset` token (it happened to share the old 90 value).
    static func pageIndicatorBottomInset(idiom: AppIdiom) -> CGFloat {
        switch idiom {
        case .compact, .regular: Space.s22
        case .tv: 90
        }
    }
    /// Height of the page's contact shadow on the artwork (`HeroEdgeShadow`). Short on purpose —
    /// occlusion shadows hug their edge; anything taller reads as a scrim, which is the legibility
    /// veils' job. tv scales with the rest of the chrome.
    static func edgeShadowHeight(idiom: AppIdiom) -> CGFloat {
        idiom == .tv ? 34 : 22
    }
    /// The per-side horizontal overscan (pt) — the smallest seam-free value, owner-tuned on
    /// device with a live slider against the worst real backdrop (2026-08-10: 2pt only weakened
    /// the line, 3.5 is the floor). Don't shave it further without re-running that tuning.
    static let edgeOverscanPoints: CGFloat = 3.5
    /// Overscan of the picture INSIDE the extension effect (iPad only — the effect is what mirrors
    /// the edge), as a UNIFORM scale: `edgeOverscanPoints` out-paints the band on each side, the
    /// vertical trim follows at the aspect's proportion (aspect preserved — an x-only scale
    /// distorted). The effect clips the overhang, leaving the boundary column interior pixels
    /// instead of somebody's antialiased edge — see the overscan note in `HeroBackdropPicture`.
    /// Derived from the resting width (bandHeight × aspect): the mid-pull drift of that estimate
    /// is a fraction of a fraction.
    static func edgeOverscanScale(bandHeight: CGFloat) -> CGFloat {
        let restingWidth = bandHeight * bandAspectRatio(regularWidth: true)
        guard restingWidth > 0 else { return 1 }
        return 1 + edgeOverscanPoints * 2 / restingWidth
    }
    /// How far the veil overlay's clamp-smear runs leading-ward past the band's edge
    /// (`HeroVeilOverlay`) — a fixed overshoot chosen to out-reach any sidebar width on any iPad;
    /// the surplus paints off-window. Deliberately NOT measured from the actual inset: the smear is
    /// horizontally constant, so overshooting costs nothing and needs no geometry plumbing.
    static let veilUnderSidebarReach: CGFloat = 600
    /// Clearance between the band's bottom edge and the detail page's first text line (the open
    /// ledger). Deliberately wider than a plain section gap: the floor bleed carries the artwork's
    /// color down onto the page here, so text sitting a section-gap away read as pinned to the
    /// artwork — the extra air lets the spill breathe before type starts. One token for BOTH
    /// detail screens (movie shipped 18pt, series 22pt — they had already drifted).
    static func floorTextClearance(idiom: AppIdiom) -> CGFloat {
        switch idiom {
        case .compact: 30
        case .regular: 34
        case .tv: 48
        }
    }
    /// How far the floor bleed (`HeroFloorBleed`) spills below the band's bottom edge. Absolute pt,
    /// not band-derived: the spill belongs to the PAGE under the band (roughly one shelf-header's
    /// worth of ambience), so it shouldn't grow with a taller poster band.
    static func floorBleedHeight(idiom: AppIdiom) -> CGFloat {
        switch idiom {
        case .compact: 170
        case .regular: 210
        case .tv: 240
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

// MARK: - Preview harness

#if !os(tvOS)
/// Assembles a hero screen the way the real call sites do — backdrop behind, spacer + foreground +
/// page inside — so every preview below exercises the PAIRING rather than half of it. A preview
/// that mounted only one half would pass while the shipping screen showed a bare page or a picture
/// with no room reserved for it.
private struct HeroPreviewScreen<Artwork: View, Foreground: View, Page: View>: View {
    var scroll: HeroScrollState? = nil
    var floorBleedHash: String? = nil
    var regularWidth: Bool
    var pageSpacing: CGFloat = Space.s30
    @ViewBuilder var artwork: () -> Artwork
    @ViewBuilder var foreground: () -> Foreground
    @ViewBuilder var page: () -> Page

    var body: some View {
        let art = artwork()
        ScrollView {
            VStack(alignment: .leading, spacing: pageSpacing) {
                HeroBand(scroll: scroll, floorBleedHash: floorBleedHash) {
                    art
                } foreground: {
                    foreground()
                }
                .heroBandFrame(regularWidth: regularWidth)
                page()
            }
        }
        .scrollClipDisabled(true)
        .heroBackdrop(scroll: scroll, artwork: art)
        .ignoresSafeArea(edges: .top)
        .environment(\.appIdiom, regularWidth ? .regular : .compact)
    }
}

/// Permanent regression diagnostic for the PINNED TOP — the twice-shipped "background exposed above
/// the hero" bug, now structurally impossible. A frozen mid-pull frame: `scroll.adjustment` carries
/// 120, exactly the state mid-gesture. The magenta floor stands in for the page floor.
/// Pass criteria:
///  • ZERO magenta above the artwork. The backdrop's frame is pinned to the canvas top and the
///    stretch is anchored `.top`, so the top edge cannot move — magenta up there means something
///    started transforming the backdrop from outside, or the pin was lost.
///  • The artwork's bottom edge sits 120pt LOWER than the resting band height (compare with the
///    "floor bleed" previews). If it stops at the resting height instead, the host frame stopped
///    growing with the pull and the extension effect is guillotining the stretch at its bounds.
#Preview("HeroBand · pinned top mid-pull (regular)", traits: .fixedLayout(width: 900, height: 760)) {
    ZStack {
        Color(red: 1, green: 0, blue: 0.6).ignoresSafeArea()
        HeroPreviewScreen(scroll: HeroScrollState(adjustment: 120), regularWidth: true) {
            LinearGradient(
                colors: [Color(red: 0.10, green: 0.16, blue: 0.36),
                         Color(red: 0.02, green: 0.36, blue: 0.44)],
                startPoint: .top, endPoint: .bottom
            )
        } foreground: {
            PreviewHeroForeground(regularWidth: true)
        } page: {
            EmptyView()
        }
    }
}

#Preview("HeroBand · pinned top mid-pull (compact)", traits: .fixedLayout(width: 393, height: 800)) {
    ZStack {
        Color(red: 1, green: 0, blue: 0.6).ignoresSafeArea()
        HeroPreviewScreen(scroll: HeroScrollState(adjustment: 120), regularWidth: false) {
            LinearGradient(
                colors: [Color(red: 0.10, green: 0.16, blue: 0.36),
                         Color(red: 0.02, green: 0.36, blue: 0.44)],
                startPoint: .top, endPoint: .bottom
            )
        } foreground: {
            PreviewHeroForeground(regularWidth: false)
        } page: {
            EmptyView()
        }
    }
}

/// Extension-effect diagnostic that works on ANY destination (no iPad sim required): a manual
/// leading `.safeAreaInset` stands in for the floating sidebar's inset — the region
/// `backgroundExtensionEffect` mirrors into — over the bright `WorstCaseArtwork` (toughest case for
/// the boundary seam). The inset is left CLEAR so the mirror is judged raw. Failure signatures:
///  • NOTHING in the inset region — the effect isn't reaching it: the backdrop lost its horizontal
///    safe area, or `regularWidth` resolved false.
///  • A hairline at the boundary — the edge overscan stopped clearing the sampled raster's own
///    edge out of the mirror (the resting-white-line fix, `edgeOverscanScale`).
///  • A pale falloff band along the seam — the mirror is meeting the artwork below full opacity.
#Preview("HeroBand · sidebar seam (simulated inset)", traits: .fixedLayout(width: 980, height: 620)) {
    HeroPreviewScreen(regularWidth: true) {
        WorstCaseArtwork()
    } foreground: {
        PreviewHeroForeground(regularWidth: true)
    } page: {
        Rectangle().fill(Color.fill).frame(height: 120).padding(.horizontal, Space.s40)
    }
    .safeAreaInset(edge: .leading, spacing: 0) {
        Color.clear.frame(width: 150).ignoresSafeArea()
    }
}

/// The same seam, mid-pull. At rest the mirror and the artwork read as one continuous image across
/// the boundary; during a pull-down BOTH sides slide into that line — the artwork's leftward growth
/// is clipped at the band's leading edge and the mirror converges into it from the other side, so
/// the line itself must not move. A boundary that drifts off 150pt means something outside the
/// effect is transforming its output.
#Preview("HeroBand · sidebar seam mid-pull", traits: .fixedLayout(width: 980, height: 700)) {
    ZStack {
        Color(red: 1, green: 0, blue: 0.6).ignoresSafeArea()
        HeroPreviewScreen(scroll: HeroScrollState(adjustment: 120), regularWidth: true) {
            WorstCaseArtwork()
        } foreground: {
            PreviewHeroForeground(regularWidth: true)
        } page: {
            EmptyView()
        }
    }
    .safeAreaInset(edge: .leading, spacing: 0) {
        Color.clear.frame(width: 150).ignoresSafeArea()
    }
}

// iPad-only diagnostic (sidebarAdaptable + sidebar bottom bar don't exist on
// tvOS); without the guard this preview alone breaks the whole tvOS build.
#Preview("HeroBand · sidebar bleed") {
    TabView {
        Tab("Home", systemImage: "house") {
            NavigationStack {
                HeroPreviewScreen(regularWidth: true) {
                    LinearGradient(
                        colors: [Color(red: 0.42, green: 0.20, blue: 0.55),
                                 Color(red: 0.0, green: 0.40, blue: 0.74)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    )
                } foreground: {
                    PreviewHeroForeground(regularWidth: true)
                } page: {
                    ForEach(0..<3) { i in
                        Text("Shelf \(i)")
                            .font(.headline)
                            .padding(.horizontal, Space.s40)
                        Rectangle().fill(Color.fill).frame(height: 120)
                            .padding(.horizontal, Space.s40)
                    }
                }
                .background(Color.background)
                // Bar dropped ON PURPOSE, diagnostic-only: this preview isolates the sidebar
                // bleed, and the bar region would sit over the exact boundary being judged.
                // Production NEVER hides the bar on hero screens (the zoom transition needs a
                // shared bar — see HomeView) — don't copy this line into a real screen.
                .toolbarVisibility(.hidden, for: .navigationBar)
            }
        }
        Tab("Library", systemImage: "rectangle.stack") { Color.background }
        // Plain tab, not `role: .search`: this diagnostic only needs a sidebar ROW in the
        // right slot — the real Search tab (RootTabView) uses the role with its `.searchable`
        // inside the tab's own stack, none of which matters to a sidebar-bleed render.
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
    // Needs an iPad run destination to be worth anything: on an iPhone destination
    // `sidebarAdaptable` falls back to bottom tabs and there is no region to extend into —
    // which makes it a useful check that the no-sidebar case is untouched, but not a look
    // at the bleed.
    .environment(\.appIdiom, .regular)
}

/// Floor-bleed seam diagnostic: the band's hard bottom edge with the item's blur spilling below it
/// onto the field, and real shelf stand-ins drawing OVER the spill — the artwork↔page transition
/// `HeroFloorBleed` exists for. The artwork slot renders the SAME BlurHash the bleed decodes, so
/// color continuity across the edge is directly judgeable: the spill must read as the artwork's
/// light continuing onto the page (no hue jump at the edge, no traceable bottom line of the bleed),
/// the band edge itself must stay crisp, and the shelf title must stay legible over the spill's
/// strongest zone. Render both schemes.
private struct FloorBleedProof: View {
    let regularWidth: Bool

    /// Vivid multi-hue sample (reference set) — worst case for a hue jump at the edge.
    private let hash = "LGF5]+Yk^6#M@-5c,1J5@[or[Q6."

    var body: some View {
        HeroPreviewScreen(floorBleedHash: hash, regularWidth: regularWidth) {
            BlurHashPlaceholder(
                hash: hash,
                aspectRatio: HeroMetrics.bandAspectRatio(regularWidth: regularWidth)
            )
        } foreground: {
            PreviewHeroForeground(regularWidth: regularWidth)
        } page: {
            VStack(alignment: .leading, spacing: Space.s12) {
                Text("Continue Watching")
                    .font(.headline)
                    .foregroundStyle(Color.label)
                HStack(spacing: Space.s12) {
                    ForEach(0..<3, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: Radius.tile, style: .continuous)
                            .fill(Color.artworkPlaceholder)
                            .aspectRatio(MediaImage.poster, contentMode: .fit)
                    }
                }
            }
            .padding(.horizontal, Space.s22)
        }
        .screenFloor()
    }
}

#Preview("HeroBand · floor bleed (compact)", traits: .fixedLayout(width: 393, height: 852)) {
    FloorBleedProof(regularWidth: false)
}

#Preview("HeroBand · floor bleed (regular)", traits: .fixedLayout(width: 1024, height: 800)) {
    FloorBleedProof(regularWidth: true)
}

/// Detail-page variant of the floor-bleed proof: the open ledger's first text line sitting
/// `HeroMetrics.floorTextClearance` below the band's edge, over the spill's strongest zone.
/// Judge the AIR between the artwork edge and the first line — the text must read as ON the
/// page under the artwork's light, not pinned to the artwork (the pre-token 18pt gap did).
private struct FloorClearanceProof: View {
    let regularWidth: Bool

    /// Same vivid multi-hue sample as `FloorBleedProof` — strongest spill under the text.
    private let hash = "LGF5]+Yk^6#M@-5c,1J5@[or[Q6."

    var body: some View {
        let idiom: AppIdiom = regularWidth ? .regular : .compact
        HeroPreviewScreen(
            floorBleedHash: hash,
            regularWidth: regularWidth,
            pageSpacing: HeroMetrics.floorTextClearance(idiom: idiom)
        ) {
            BlurHashPlaceholder(
                hash: hash,
                aspectRatio: HeroMetrics.bandAspectRatio(regularWidth: regularWidth)
            )
        } foreground: {
            PreviewHeroForeground(regularWidth: regularWidth)
        } page: {
            // Ledger stand-in: an overview paragraph + a caption line, the detail page's
            // first text under the band (mirrors DetailMetadataSection's type tiers).
            VStack(alignment: .leading, spacing: Space.s12) {
                Text("A crew on humanity's last orbital station races to prevent a cascade failure before re-entry, rationing oxygen while the ground crew fights to reach them in time.")
                    .font(.subheadline)
                    .foregroundStyle(Color.label)
                    .frame(maxWidth: HeroMetrics.overviewMaxWidth(idiom: idiom), alignment: .leading)
                Text("Science Fiction · Thriller")
                    .font(.caption)
                    .foregroundStyle(Color.secondaryLabel)
            }
            .padding(.horizontal, AppLayout.contentHMargin(idiom: idiom))
        }
        .screenFloor()
    }
}

#Preview("HeroBand · floor clearance (compact)", traits: .fixedLayout(width: 393, height: 852)) {
    FloorClearanceProof(regularWidth: false)
}

#Preview("HeroBand · floor clearance (regular)", traits: .fixedLayout(width: 1024, height: 800)) {
    FloorClearanceProof(regularWidth: true)
}

/// Permanent diagnostic: white text over deliberately hostile bright artwork, both band
/// variants. Compact judges the bottom fade; regular judges the bare band, where the type's own
/// contours (`heroTypeContour`) are the whole protection — the stand-in below applies the same
/// shipping treatments so this render shows the true accepted worst case.
// `.fixedLayout` so the canvas IS the band size — otherwise a wide iPad band rendered on an
// iPhone destination overflows and clips to the center, hiding the bottom-leading panel.
#Preview("Hero legibility · panel (regular)", traits: .fixedLayout(width: 1024, height: 576)) {
    HeroPreviewScreen(regularWidth: true) {
        WorstCaseArtwork()
    } foreground: {
        PreviewHeroForeground(regularWidth: true)
    } page: {
        EmptyView()
    }
}

#Preview("Hero legibility · fade (compact)", traits: .fixedLayout(width: 420, height: 630)) {
    HeroPreviewScreen(regularWidth: false) {
        WorstCaseArtwork()
    } foreground: {
        PreviewHeroForeground(regularWidth: false)
    } page: {
        EmptyView()
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
                // Mirror the shipping type treatment (HeroTitle's text title) so the
                // legibility renders judge what actually ships.
                .heroTypeContour(idiom: idiom)
            AdaptiveHeroOverview(
                text: "A crew on humanity's last orbital station races to prevent a cascade failure before re-entry, rationing oxygen while the ground crew fights to reach them in time."
            )
            Label("Play", systemImage: "play.fill")
                .font(.headline).foregroundStyle(Color.playerInk)
                .padding(.horizontal, Space.s22).frame(height: 46)
                // Mirror PrimaryPlayButton's shipping face: white-tinted dark-pinned glass on
                // iPhone/iPad (this preview file is !tvOS, so no flat branch needed).
                .glassEffect(.regular.tint(.white), in: Capsule())
                .environment(\.colorScheme, .dark)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, Space.s8)
        }
        .frame(maxHeight: HeroMetrics.foregroundMaxHeight(idiom: idiom), alignment: .bottom)
    }
}
#endif
