import CoreGraphics
import SwiftUI
import Testing
import UIKit
@testable import Parallax

struct AppLayoutTests {
    @Test("tv idiom uses 40pt content inset and 6 poster columns")
    func tvMetrics() {
        #expect(AppLayout.contentHMargin(idiom: .tv) == 40)
        #expect(AppLayout.posterGridColumns(idiom: .tv) == 6)
        #expect(AppLayout.posterGridColumnSpacing(idiom: .tv) == 40)
        #expect(AppLayout.posterGridRowSpacing(idiom: .tv) == 40)
        #expect(AppLayout.shelfTileWidth(idiom: .tv) == 220)
        #expect(AppLayout.libraryListColumns(idiom: .tv) == 3)
    }

    @Test("compact idiom preserves iPhone metrics")
    func compactMetrics() {
        #expect(AppLayout.contentHMargin(idiom: .compact) == 18)
        #expect(AppLayout.posterGridColumns(idiom: .compact) == 3)
    }

    @Test("iOS poster grids: tokenized s12 columns / s16 rows (caption breathing room)")
    func iosPosterGridSpacing() {
        for idiom in [AppIdiom.compact, .regular] {
            #expect(AppLayout.posterGridColumnSpacing(idiom: idiom) == Space.s12)
            #expect(AppLayout.posterGridRowSpacing(idiom: idiom) == Space.s16)
        }
    }

    @Test("regular idiom preserves iPad metrics")
    func regularMetrics() {
        #expect(AppLayout.contentHMargin(idiom: .regular) == 20)
        #expect(AppLayout.posterGridColumns(idiom: .regular) == 5)
    }

    @Test("landscape hero band on regular and tv only")
    func heroBand() {
        #expect(AppIdiom.compact.usesLandscapeHeroBand == false)
        #expect(AppIdiom.regular.usesLandscapeHeroBand == true)
        #expect(AppIdiom.tv.usesLandscapeHeroBand == true)
    }

    @Test("hero parallax lags the artwork at half speed, scroll-down only")
    func heroParallaxShift() {
        // Negative adjustment = scrolled into the feed → artwork lags at half speed.
        #expect(HeroMetrics.parallaxShift(forScrollAdjustment: -100) == 50)
        // Positive = pull-down rubber-band — that side belongs to the stretch zoom.
        #expect(HeroMetrics.parallaxShift(forScrollAdjustment: 80) == 0)
        #expect(HeroMetrics.parallaxShift(forScrollAdjustment: 0) == 0)
    }

    /// Real alpha of each stop, extracted from the returned colors — the assertions must
    /// run against the function's OUTPUT, not a recomputed twin of its formula (a twin
    /// passes even when the implementation regresses).
    private func alphas(_ stops: [Gradient.Stop]) -> [Double] {
        stops.map { Double(UIColor($0.color).cgColor.alpha) }
    }

    @Test("hero scrim ramp: clear through `from`, eased monotonically to maxOpacity")
    func heroScrimEasedStops() {
        let wash = HeroScrim.easedStops(from: 0.4, maxOpacity: 0.7)
        // Clear at the band top AND at the ramp onset — no hard edge anywhere.
        #expect(wash.first?.location == 0)
        #expect(wash[1].location == 0.4)
        #expect(wash.last?.location == 1.0)
        // Locations and opacity both non-decreasing (a non-monotonic ramp would band).
        let locations = wash.map(\.location)
        #expect(locations == locations.sorted())
        let washAlphas = alphas(wash)
        #expect(washAlphas.first == 0)
        #expect(abs(washAlphas.last! - 0.7) < 0.005)
        #expect(washAlphas == washAlphas.sorted())

        // The taper masks: opaque through `from`, easing DOWN to `minimum` — never to zero
        // (a zero tail would cut the stroke off and reintroduce a visible edge).
        let mask = HeroScrim.easedMaskStops(from: 0.4, minimum: 0.55)
        #expect(mask.first?.location == 0)
        #expect(mask[1].location == 0.4)
        #expect(mask.last?.location == 1.0)
        let maskLocations = mask.map(\.location)
        #expect(maskLocations == maskLocations.sorted())
        let maskAlphas = alphas(mask)
        #expect(maskAlphas.first == 1.0)
        #expect(abs(maskAlphas.last! - 0.55) < 0.005)
        #expect(maskAlphas == maskAlphas.sorted(by: >))
    }

    @Test("hero scrim shipping recipes: tapers never fade a stroke out")
    func heroScrimRecipeInvariants() {
        // The leading taper's floor is the seam guard: its leading column is what the
        // sidebar extension effect mirrors — a clear top re-brightens the mirrored strip
        // and the boundary hairline returns. The bottom taper's floor keeps the band's
        // lower edge continuous across the full width.
        #expect(alphas(HeroScrim.leadingTaper).min()! >= 0.45)
        #expect(alphas(HeroScrim.bottomTaper).min()! >= 0.5)
        // Washes peak strictly inside (0, 1): fully opaque would crush the artwork,
        // zero would mean no scrim at all.
        for recipe in [HeroScrim.compactBottom, HeroScrim.regularBottom, HeroScrim.regularLeading] {
            let peak = alphas(recipe).max()!
            #expect(peak > 0.5 && peak < 0.85)
        }
    }

    @Test("hero stretch zoom: pull-down only, proportional to band height, safe at zero height")
    func heroStretchScale() {
        #expect(HeroMetrics.stretchScale(forScrollAdjustment: 100, bandHeight: 400) == 1.25)
        // Scroll-down belongs to the parallax, not the stretch.
        #expect(HeroMetrics.stretchScale(forScrollAdjustment: -100, bandHeight: 400) == 1)
        #expect(HeroMetrics.stretchScale(forScrollAdjustment: 0, bandHeight: 400) == 1)
        // First-pass geometry can propose a zero-height band; never divide by it.
        #expect(HeroMetrics.stretchScale(forScrollAdjustment: 100, bandHeight: 0) == 1)
    }

    @Test("tvOS hero foreground re-aligns with the title-safe shelves after full-bleed")
    func tvHeroForegroundAlignsWithShelves() {
        // The hero artwork bleeds full-width (`heroScreenSafeArea()` drops the horizontal
        // overscan), so its foreground must re-inset in ABSOLUTE terms to the same gutter the
        // shelves land on: the re-added overscan (`tvContentInset()`) PLUS each shelf's own
        // `contentHMargin`. If these drift, the hero title/Play stop lining up with the rows.
        #expect(AppLayout.tvOverscanInset == 90)
        #expect(
            HeroMetrics.foregroundHorizontalInset(idiom: .tv)
                == AppLayout.tvOverscanInset + AppLayout.contentHMargin(idiom: .tv)
        )
        // iPhone/iPad keep the safe area, so their hero inset is the raw content margin.
        #expect(HeroMetrics.foregroundHorizontalInset(idiom: .compact) == Space.s22)
        #expect(HeroMetrics.foregroundHorizontalInset(idiom: .regular) == Space.s40)
    }
}