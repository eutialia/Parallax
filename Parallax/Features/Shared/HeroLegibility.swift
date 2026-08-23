import SwiftUI

// Hero legibility — what keeps the white title/actions readable over artwork we don't control.
// Idiom-split by STRUCTURE, not taste (owner-settled 2026-08-10): a band-level treatment only
// reads as UI when its geometry matches a UI structure. On the tall iPhone band the text column
// spans the full width, so a full-width frosted bottom fade (`HeroBottomFade`) reads as the
// column's own backing — it stays. On the wide landscape band (iPad/tvOS) the foreground is a
// bottom-leading corner column: a full-width band washed acres of empty artwork, and the
// corner-focused ellipse (`HeroCornerFade`, deleted) mapped to no visible structure and read as a
// smudge on the photo — so the wide band carries NO veil at all; the type protects itself with
// the tight per-glyph contours below (`heroTypeContour`/`heroLogoContour`). A WIDE SOFT HALO on
// the whole column was tried first and killed the same day — a halo reads as a layer, a contour
// reads as part of the letterform; keep that distinction when tuning. `HeroEdgeShadow` is not a
// veil — it's the band boundary's depth cue and stays on every idiom.
//
// On iPhone/iPad the treatments ride ABOVE the `backgroundExtensionEffect` (`HeroVeilOverlay`
// continues them under the iPad sidebar with a clamp-smear); tvOS composites them with the artwork.

/// Frosted bottom fade — the compact (iPhone) legibility. A full-width band-level layer: fills the
/// band, then frosts + scrims the bottom `coverage` fraction (progressive `.ultraThinMaterial` ramp
/// + dark scrim, pinned dark), so the title/actions seated at the bottom stay legible over any
/// artwork. The fraction is measured off the band, so it scales across device sizes.
struct HeroBottomFade: View {
    /// How far up the band the fade rises (0–1 of band height).
    private static let coverage: CGFloat = 0.66

    var body: some View {
        GeometryReader { proxy in
            Color.clear
                .frame(maxWidth: .infinity)
                .frame(height: proxy.size.height * Self.coverage)
                .shelfTileFooterGlass()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Type contour (wide screens)

extension View {
    /// Subtitle-style contour for hero TYPE over the bare wide-band artwork (owner-requested
    /// 2026-08-10): a tight dark shadow hugging the glyph edges — the video-subtitle recipe, not
    /// the big soft halo (that variant was tried on the whole column and killed the same day; a
    /// wide halo reads as a layer, a contour reads as part of the letterform). Compact is a
    /// no-op: the iPhone band keeps its bottom fade and its signed-off look.
    @ViewBuilder
    func heroTypeContour(idiom: AppIdiom) -> some View {
        if idiom == .compact {
            self
        } else {
            self.shadow(color: .black.opacity(0.65), radius: 1.5, x: 0, y: 1)
        }
    }

    /// The LOGO variant: same idea, softer and larger — a wordmark PNG is a big shape, and the
    /// 1.5pt text contour under it reads as a rendering artifact. SwiftUI's `shadow` follows the
    /// view's alpha, so the trimmed transparent PNG casts a letter-shaped plate, not a box.
    /// Compact no-op for the same reason as `heroTypeContour`.
    @ViewBuilder
    func heroLogoContour(idiom: AppIdiom) -> some View {
        if idiom == .compact {
            self
        } else {
            self.shadow(color: .black.opacity(0.45), radius: 7, x: 0, y: 2)
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
/// shadow (not a scrim — legibility belongs to the compact fade / the type contours). On
/// iPhone/iPad it rides `HeroVeilTreatments` ABOVE the extension effect (never mirrored; the
/// clamp-smear continues it under the iPad sidebar so the mirror darkens in lockstep); tvOS
/// composites it with the artwork. The darkened strip doubles as extra backing for the page
/// dots seated on the edge. Bottom-aligned by the treatments' `.bottomLeading` ZStack; the
/// caller sets the height (`edgeShadowHeight`).
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

