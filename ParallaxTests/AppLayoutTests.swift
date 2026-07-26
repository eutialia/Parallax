import CoreGraphics
import SwiftUI
import Testing
import UIKit
@testable import Parallax

/// Every per-idiom layout number in one row.
struct IdiomMetrics: Sendable, CustomTestStringConvertible {
    let idiom: AppIdiom
    let contentHMargin: CGFloat
    let posterColumns: Int
    let posterColumnSpacing: CGFloat
    let posterRowSpacing: CGFloat
    let landscapeColumns: Int
    let shelfTileWidth: CGFloat
    let libraryListColumns: Int
    var testDescription: String { "\(idiom)" }
}

private let idiomMetrics: [IdiomMetrics] = [
    // 16 = the system compact layout margin, where the nav bar also parks its trailing glass
    // circles — the library sort button lines up with the grid edge only at this value
    // (render-measured). iOS poster grids use the tokenized s12/s16 spacing (caption breathing room).
    // iOS shelves share ONE tile width — `HomeShelf.tileWidth` is the source of truth, referenced
    // rather than re-typed, because both idioms are meant to move together if it's retuned.
    IdiomMetrics(
        idiom: .compact, contentHMargin: 16, posterColumns: 3,
        posterColumnSpacing: Space.s12, posterRowSpacing: Space.s16,
        landscapeColumns: 2, shelfTileWidth: HomeShelf.tileWidth, libraryListColumns: 1
    ),
    IdiomMetrics(
        idiom: .regular, contentHMargin: 20, posterColumns: 5,
        posterColumnSpacing: Space.s12, posterRowSpacing: Space.s16,
        landscapeColumns: 4, shelfTileWidth: HomeShelf.tileWidth, libraryListColumns: 2
    ),
    IdiomMetrics(
        idiom: .tv, contentHMargin: 40, posterColumns: 6,
        posterColumnSpacing: 40, posterRowSpacing: 40,
        landscapeColumns: 5, shelfTileWidth: 220, libraryListColumns: 3
    ),
]

struct AppLayoutTests {
    /// The per-idiom numbers, in one table. These ARE the design handoff (they have no derivation to
    /// assert against), so they stay literal — but as one row per idiom rather than three near-identical
    /// tests, which is what made the compact/regular pair drift into asserting different subsets.
    @Test("per-idiom layout metrics", arguments: idiomMetrics)
    func metrics(_ expected: IdiomMetrics) {
        let idiom = expected.idiom
        #expect(AppLayout.contentHMargin(idiom: idiom) == expected.contentHMargin)
        #expect(AppLayout.posterGridColumns(idiom: idiom) == expected.posterColumns)
        #expect(AppLayout.posterGridColumnSpacing(idiom: idiom) == expected.posterColumnSpacing)
        #expect(AppLayout.posterGridRowSpacing(idiom: idiom) == expected.posterRowSpacing)
        #expect(AppLayout.landscapeGridColumns(idiom: idiom) == expected.landscapeColumns)
        #expect(AppLayout.shelfTileWidth(idiom: idiom) == expected.shelfTileWidth)
        #expect(AppLayout.libraryListColumns(idiom: idiom) == expected.libraryListColumns)
    }

    /// A 16:9 tile is far wider than a 2:3 poster at the same column width, so a landscape grid must
    /// thin its columns relative to the poster count — never match or exceed it, or the tiles render
    /// short and cramped. The invariant, unlike the counts above, holds through any retune.
    @Test("landscape grids always run fewer columns than poster grids", arguments: [AppIdiom.compact, .regular, .tv])
    func landscapeGridsAreThinner(idiom: AppIdiom) {
        #expect(AppLayout.landscapeGridColumns(idiom: idiom) < AppLayout.posterGridColumns(idiom: idiom))
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

    @Test("tvOS hero fills the screen: full-viewport fallback fraction + a 16:9 band for a 16:9 TV")
    func tvHeroSpansViewport() {
        // The band fills the true screen via the measured `heroViewportHeight` (runtime layout, not
        // unit-testable); this pins the two constants that back it. The fallback fraction is 1.0 so
        // the first frame (before the measurement lands) is already as close to full as the safe area
        // allows — drop it and the hero would settle from a visibly shorter band. The landscape band
        // is MediaImage.landscape (16:9), matching a 16:9 TV, so the backdrop fills with no crop.
        #expect(HeroMetrics.tvHeroHeightFraction == 1.0)
        #expect(HeroMetrics.bandAspectRatio(regularWidth: true) == MediaImage.landscape)
    }

    @Test("page dots: compact/regular tuck under the action row; tvOS dots clear overscan, below the lifted controls")
    func pageIndicatorInset() {
        // Compact + regular tuck the dots just below the action row — the old iPhone Space.s3
        // jammed them against the poster's bottom seam.
        #expect(HeroMetrics.pageIndicatorBottomInset(idiom: .compact) == Space.s22)
        #expect(HeroMetrics.pageIndicatorBottomInset(idiom: .regular) == Space.s22)
        // tvOS: dots sit at the title-safe line near the bottom; the focusable controls are lifted
        // higher (clear of the focus-scroll zone on the full-bleed hero), so controls > dots.
        #expect(HeroMetrics.pageIndicatorBottomInset(idiom: .tv) == AppLayout.tvOverscanInset)
        #expect(HeroMetrics.foregroundBottomInset(idiom: .tv) > HeroMetrics.pageIndicatorBottomInset(idiom: .tv))
    }
}
