import SwiftUI

// Hero legibility — the treatment that keeps the white title/actions readable over artwork we
// don't control. It lives entirely on the FOREGROUND side of the band (never the artwork), so it
// never appears in the iPad sidebar `backgroundExtensionEffect` reflection (only the raw artwork is
// mirrored). It replaces the old full-band gradient wash (`HeroBandScrim`), which gambled on the
// image and washed the whole frame.
//
// One mechanism on both idioms now: a frosted bottom fade — the SAME progressive blur + scrim recipe
// the Continue Watching shelf footers use (`shelfTileFooterGlass`). The earlier opaque floating
// panel read as a dark box dropped in the corner of a wide photo; the fade reads as a cinematic base
// the content sits on. iPhone and iPad differ only in how far up the fade rises (`coverage`).

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

/// Corner-focused frosted glow — the LANDSCAPE (iPad / tvOS) legibility. An elliptical frost + scrim
/// centered ON the bottom-leading title block (not the empty corner), fading out toward the
/// top-right. On a wide band a flat bottom strip darkens a lot of empty artwork; this concentrates
/// the darkening where the text actually is. Focus/spread/darkness were dialed in the
/// `docs/hero-fade-demo.html` prototype; `EllipticalGradient` maps the CSS radial 1:1 (same focus,
/// same stop locations, `endRadiusFraction` = the prototype's spread). Pinned dark so the material
/// resolves to its dark frosted variant over photography.
struct HeroCornerFade: View {
    var focus = UnitPoint(x: 0.15, y: 0.80)
    var spread: CGFloat = 0.90
    var darkness: Double = 0.40

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)
                .mask(
                    EllipticalGradient(
                        stops: [
                            .init(color: .black, location: 0),
                            .init(color: .black, location: 0.16),
                            .init(color: .clear, location: 0.70),
                        ],
                        center: focus,
                        endRadiusFraction: spread
                    )
                )
            EllipticalGradient(
                stops: [
                    .init(color: .black.opacity(darkness), location: 0),
                    .init(color: .black.opacity(darkness * 0.5), location: 0.34),
                    .init(color: .clear, location: 0.70),
                ],
                center: focus,
                endRadiusFraction: spread
            )
        }
        .environment(\.colorScheme, .dark)
        .allowsHitTesting(false)
    }
}
