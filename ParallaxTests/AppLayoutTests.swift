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
        // 16 = the system compact layout margin, where the nav bar also parks
        // its trailing glass circles — the library sort button lines up with
        // the grid edge only at this value (render-measured).
        #expect(AppLayout.contentHMargin(idiom: .compact) == 16)
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

    @Test("landscape (SMB) grids run fewer columns than poster grids on every idiom")
    func landscapeGridColumns() {
        #expect(AppLayout.landscapeGridColumns(idiom: .compact) == 2)
        #expect(AppLayout.landscapeGridColumns(idiom: .regular) == 4)
        #expect(AppLayout.landscapeGridColumns(idiom: .tv) == 4)
        // A 16:9 tile is far wider than a 2:3 poster at the same column width, so a landscape
        // grid must thin its columns relative to the poster count — never match or exceed it,
        // or the tiles render short and cramped.
        for idiom in [AppIdiom.compact, .regular, .tv] {
            #expect(AppLayout.landscapeGridColumns(idiom: idiom) < AppLayout.posterGridColumns(idiom: idiom))
        }
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
}