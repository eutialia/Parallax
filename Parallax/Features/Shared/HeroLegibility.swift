import SwiftUI

// Hero legibility — the treatment that keeps the white title/actions readable over artwork we
// don't control. It sits between the artwork and the foreground, and `HeroBand` composites it WITH
// the artwork into the layer the iPad sidebar `backgroundExtensionEffect` samples — so the mirrored
// sidebar strip carries the same veil as the main side (no luminance seam at the boundary). It
// replaces the old full-band gradient scrim, which gambled on the image and washed the whole frame.
//
// Two idiom-split frosted treatments, both the SAME `.ultraThinMaterial` + scrim recipe the
// Continue Watching shelf footers use (`shelfTileFooterGlass`), pinned dark: the tall poster band
// (iPhone) gets a full-width bottom fade; the wide landscape band (iPad/tvOS) gets a corner-focused
// glow so the darkening sits on the bottom-leading text, not the empty right side. The earlier
// opaque floating panel read as a dark box dropped in the corner of a wide photo; the fades read as
// a cinematic base the content sits on.

/// Frosted bottom fade — the compact (iPhone) legibility. A full-width band-level layer: fills the
/// band, then frosts + scrims the bottom `coverage` fraction (progressive `.ultraThinMaterial` ramp
/// + dark scrim, pinned dark), so the title/actions seated at the bottom stay legible over any
/// artwork. The fraction is measured off the band, so it scales across device sizes.
struct HeroBottomFade: View {
    /// How far up the band the fade rises (0–1 of band height). Higher = taller fade.
    var coverage: CGFloat = 0.66

    var body: some View {
        GeometryReader { proxy in
            Color.clear
                .frame(maxWidth: .infinity)
                .frame(height: proxy.size.height * coverage)
                .shelfTileFooterGlass()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        }
        .allowsHitTesting(false)
    }
}

/// Floor bleed — the artwork's light spilling PAST the band's bottom edge onto the page, instead of
/// any treatment on the artwork itself. Third design of the band-bottom transition, and the keeper
/// (owner directive 2026-07-18): v1 painted floor color over the artwork (frost kept running under
/// the paint + the flat token never matched the field's local tone → visible haze and a step); v2
/// alpha-masked the artwork into the floor (seam solved, but it washed out the page dots that sit on
/// the band's bottom edge). This version leaves the artwork's edge fully intact — dots included —
/// and paints the CONTINUATION below it: a LIVING `MeshGradient` seeded from the item's BlurHash —
/// the mesh colours are the hash's own cosine field sampled bottom-up (mirrored, so the artwork's
/// bottom colours sit at the spill's top, colour-continuous across the edge). The life is COLOUR
/// TRAVEL, not geometry: each mesh row re-samples the field per tick through a slowly drifting
/// window (`rowDrifts` — the LED-strip model), so the artwork's features themselves wander along
/// the strip, with a residual point wave (`meshPoints`) as texture underneath. No raster involved —
/// the colours come straight from the decoded coefficients, and the mesh interpolates on the GPU.
///
/// Sized and placed by `HeroBand` (an overlay hung below the band's bounds, so later scroll
/// siblings — shelf titles, tiles, the detail ledger — draw over it and it reads as ambience behind
/// the page, not a layer on it). `nil`/malformed hash = no bleed: the clean hard edge ships as-is.
/// Reduce Motion pins the mesh to its resting grid — the spill stays, the breathing stops.
/// Alpha mask that feathers `HeroCornerFade`'s darkening WASH out of the contact-shadow zone: full
/// strength until the band's last `featherHeight`, then easing to a whisper at the edge. Without
/// it, the wash stacks with `HeroEdgeShadow` in the leading corner and the occlusion line reads
/// heavier on the left than the right — the depth grammar wants ONE uniform shadow along the edge
/// (frost = artwork atmosphere, shadow = page occlusion). Applied to the wash ONLY: masking the
/// material frost too left a visible gap where the blur lifted off above the boundary. A
/// `featherHeight` of 0 degrades to a full-strength mask (no feather). Not applied to the compact
/// `HeroBottomFade`: the full-width poster frost backs the page dots and is part of that band's look.
struct VeilEdgeFeather: View {
    let featherHeight: CGFloat

    var body: some View {
        // The curve is tuned against `HeroEdgeShadow`'s ramp so their SUM stays monotonic down the
        // last stretch: an earlier, steeper feather (to 0.12 at the edge) outran the shadow's ramp
        // and the combined darkness dipped ~10pt above the boundary — a visible lighter band that
        // read as a gap between the frost and the edge (owner-caught, zoom-verified). The 0.40
        // floor keeps just enough wash at the edge for the shadow to take over seamlessly, while
        // still killing most of the old left-corner stacking.
        VStack(spacing: 0) {
            Rectangle().fill(.black)
            LinearGradient(
                stops: [
                    .init(color: .black, location: 0),
                    .init(color: .black.opacity(0.72), location: 0.55),
                    .init(color: .black.opacity(0.40), location: 1),
                ],
                startPoint: .top, endPoint: .bottom
            )
            .frame(height: featherHeight)
        }
    }
}

/// The edge-depth cue — the band boundary read as ELEVATION, not decoration (owner-directed
/// 2026-07-18, after the colored "picture rail" flopped): the page below the band is a surface
/// standing IN FRONT of the artwork's plane, supporting it, and ALL of the depth is drawn on the
/// artwork's side — this contact shadow, cast by the page up onto the recessed artwork. The page
/// itself stays a seamless whole (a 1pt specular "lip" on its top edge shipped briefly and read as
/// a stray white line by day — owner-killed; no chrome on the page side, ever). The floor bleed
/// then reads as the artwork's light washing down onto that surface — one coherent physical story.
///
/// A short darkening ramp hugging the band's bottom edge, tight and soft like a real occlusion
/// shadow (not a scrim — the legibility veils own that job). Lives INSIDE the artwork+veil
/// composite so the iPad sidebar mirror darkens in lockstep, and the darkened strip doubles as
/// extra backing for the page dots seated on the edge. Bottom-aligned by the composite's
/// `.bottomLeading` ZStack; the caller sets the height (`edgeShadowHeight`).
struct HeroEdgeShadow: View {
    var body: some View {
        LinearGradient(
            stops: [
                .init(color: .clear, location: 0),
                .init(color: .black.opacity(0.04), location: 0.45),
                .init(color: .black.opacity(0.10), location: 0.8),
                .init(color: .black.opacity(0.19), location: 1),
            ],
            startPoint: .top, endPoint: .bottom
        )
        .allowsHitTesting(false)
    }
}

struct HeroFloorBleed: View {
    let hash: String?

    /// Overall intensity of the spill. Sub-1 so the field stays the ground and ink shelf titles
    /// keep contrast over the bleed's strongest zone — it's lighting, not a second artwork.
    private let strength: Double = 0.7

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Scroll-viewport visibility (the bleed lives inside the hero's scroll content). Drives the
    /// timeline's `paused:` so the 20 fps mesh work stops once the hero is scrolled out of the
    /// feed — without this the animation ran for the whole session after one scroll-down, burning
    /// CPU/GPU on invisible pixels (review-caught). Starts `true`: `onScrollVisibilityChange`
    /// fires on appearance, and a bleed born off-screen gets paused by that first callback.
    /// Known gap, accepted: a hero COVERED by a push or the player (not scrolled) still ticks.
    @State private var isVisibleInScroll = true

    var body: some View {
        ZStack {
            // The hash is PARSED outside the timeline (base83 decode, once per hash); per tick we
            // re-SAMPLE its cosine field — 15 evaluations, microseconds — with each row's sampling
            // window drifted sideways (`rowDrifts`). Rows sample artwork-y 1.0 → 0.6: the mirrored
            // read (bottom colours at the spill's top, hue-continuous across the band edge),
            // spanning about the same stretch of image the old static reflection strip showed.
            if let hash, let meshField = BlurHashDecoder.meshField(from: hash) {
                TimelineView(
                    .animation(minimumInterval: 1.0 / 20.0, paused: reduceMotion || !isVisibleInScroll)
                ) { context in
                    let t: TimeInterval? =
                        reduceMotion ? nil : context.date.timeIntervalSinceReferenceDate
                    MeshGradient(
                        width: Self.columns, height: Self.rows,
                        points: Self.meshPoints(at: t),
                        colors: meshField.colors(
                            columns: Self.columns, rows: Self.rows,
                            yStart: 1.0, yEnd: 0.6,
                            rowXOffsets: Self.rowDrifts(at: t)
                        )
                    )
                }
                .opacity(strength)
                // Quadratic fade (alpha ∝ (1−t)²): strong right at the edge where continuity
                // matters, a long gentle tail into the field — a linear ramp reads as a band.
                .mask {
                    LinearGradient(
                        stops: [
                            .init(color: .black, location: 0),
                            .init(color: .black.opacity(0.56), location: 0.25),
                            .init(color: .black.opacity(0.25), location: 0.5),
                            .init(color: .black.opacity(0.06), location: 0.75),
                            .init(color: .clear, location: 1),
                        ],
                        startPoint: .top, endPoint: .bottom
                    )
                }
                // Identity = the hash: a carousel page change swaps the bleed with a crossfade,
                // echoing the artwork's own `CrossfadeArtwork` behaviour above it.
                .id(hash)
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.6), value: hash)
        // Any sliver visible keeps the sea alive; pause only once the strip is fully gone.
        .onScrollVisibilityChange(threshold: 0.01) { isVisibleInScroll = $0 }
        .allowsHitTesting(false)
    }

    /// Mesh articulation: 5 columns is the SAMPLING resolution for the drifting colour features
    /// (finer grid = smoother feature travel), not the motion source — the motion lives in
    /// `rowDrifts`. Two earlier cuts animated only the mesh POINTS and both under-delivered
    /// (owner-observed via sped-up screen recordings): visible motion there is the product of
    /// point displacement × colour contrast between adjacent cells, and the contrast term belongs
    /// to the artwork — over a tonally flat stretch of the hash, no amount of geometry ever shows.
    private static let columns = 5
    private static let rows = 3

    /// Per-row horizontal offsets for the colour SAMPLING window — the primary motion (the LED-strip
    /// model, owner-directed 2026-07-18): instead of jiggling geometry between frozen colours, each
    /// row slides its sampling window through the hash's cosine field, so the artwork's own colour
    /// features travel left↔right along the strip — through every column, including the tonally
    /// flat ones the point wave could never animate. Amplitude grows with depth (the row at the
    /// artwork's edge drifts least — the reflection is most faithful at the surface — but it DOES
    /// drift: the blend hides exact colour registration, owner-confirmed) and the periods are
    /// incommensurate with each other and with `meshPoints`' wave, so the sea never visibly loops.
    /// The field is even + 2-periodic, so out-of-range sampling mirrors seamlessly (see
    /// `MeshField.colors`). `nil` (Reduce Motion) = the resting alignment.
    private static func rowDrifts(at t: TimeInterval?) -> [Float] {
        guard let t else { return [0, 0, 0] }
        return [
            Float(0.08 * sin(2 * Double.pi * t / 19)),
            Float(0.17 * sin(2 * Double.pi * t / 13 + 2.1)),
            Float(0.26 * sin(2 * Double.pi * t / 23 + 4.4)),
        ]
    }

    /// The mesh at time `t` — now the TEXTURE layer under `rowDrifts`' colour travel: a slow
    /// travelling wave in the middle row's vertical displacement (phase-shifted by x so a crest
    /// rolls leading → trailing), a weaker counter-travelling term breaking the metronome, and a
    /// ~31 s amplitude envelope letting the whole sea swell and relax. Periods are incommensurate
    /// so it never visibly loops. Boundary rows stay pinned to the top/bottom edges and the outer
    /// columns to the sides (the strip must always cover its box) — but the side points DO ride the
    /// wave vertically along their edges, so the motion reaches the strip's ends instead of dying
    /// at the last interior point. `nil` (Reduce Motion) = the flat resting grid.
    private static func meshPoints(at t: TimeInterval?) -> [SIMD2<Float>] {
        var points: [SIMD2<Float>] = []
        points.reserveCapacity(columns * rows)
        for row in 0..<rows {
            let v = Float(row) / Float(rows - 1)
            for col in 0..<columns {
                let u = Float(col) / Float(columns - 1)
                var x = u
                var y = v
                if let t, row == 1 {
                    let travel = 2 * Double.pi * (t / 14) - Double(u) * (2 * .pi * 0.75)
                    let counter = 2 * Double.pi * (t / 9) + Double(u) * (2 * .pi * 0.5)
                    let envelope = 0.7 + 0.3 * sin(2 * Double.pi * t / 31)
                    y += Float((0.10 * sin(travel) + 0.04 * sin(counter)) * envelope)
                    if col != 0, col != columns - 1 {
                        x += Float(0.025 * sin(travel + 1.1) * envelope)
                    }
                }
                points.append(SIMD2(x, y))
            }
        }
        return points
    }
}

/// Corner-focused frosted glow — the LANDSCAPE (iPad / tvOS) legibility. An elliptical frost + scrim
/// centered ON the bottom-leading title block (not the empty corner), fading out toward the
/// top-right. On a wide band a flat bottom strip darkens a lot of empty artwork; this concentrates
/// the darkening where the text actually is. Focus/spread/darkness were dialed in the
/// `docs/hero-fade-demo.html` prototype; `EllipticalGradient` maps the CSS radial 1:1 (same focus,
/// same stop locations, `endRadiusFraction` = the prototype's spread). Pinned dark so the material
/// resolves to its dark frosted variant over photography.
struct HeroCornerFade: View {
    var focus = UnitPoint(x: 0.16, y: 0.78)
    var spread: CGFloat = 0.90
    var darkness: Double = 0.40
    /// Height of the bottom strip where the darkening WASH yields to `HeroEdgeShadow` (the page's
    /// contact shadow), so the two never stack into a leading-corner-heavy edge. The MATERIAL frost
    /// deliberately keeps running to the edge — feathering it too left a visible "frost lifts off
    /// here" gap above the boundary (owner-caught); the blur is harmless under the shadow, only the
    /// black wash fought it. 0 = no feather (the wash runs full height).
    var washFeatherHeight: CGFloat = 0

    /// Frost distribution (owner-tuned 2026-07-18 via the extent ruler): the plateau runs at ~78%
    /// mask alpha — full material read as too heavy over the title block — and the fade shoulder is
    /// raised + stretched (mid stop 0.58 @ 0.42, reach out to 0.74) so the total atmosphere is
    /// conserved: less blur where the text sits, more carried by the surround.
    private static let plateauEnd: CGFloat = 0.16
    private static let reach: CGFloat = 0.74

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)
                .mask(
                    EllipticalGradient(
                        stops: [
                            .init(color: .black.opacity(0.78), location: 0),
                            .init(color: .black.opacity(0.78), location: Self.plateauEnd),
                            .init(color: .black.opacity(0.58), location: 0.42),
                            .init(color: .clear, location: Self.reach),
                        ],
                        center: focus,
                        endRadiusFraction: spread
                    )
                )
            EllipticalGradient(
                stops: [
                    .init(color: .black.opacity(darkness), location: 0),
                    .init(color: .black.opacity(darkness * 0.5), location: 0.34),
                    .init(color: .clear, location: Self.reach),
                ],
                center: focus,
                endRadiusFraction: spread
            )
            .mask { VeilEdgeFeather(featherHeight: washFeatherHeight) }
        }
        .environment(\.colorScheme, .dark)
        .allowsHitTesting(false)
    }
}
