import CoreGraphics
import Testing
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