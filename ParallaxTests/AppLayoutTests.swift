import CoreGraphics
import Testing
@testable import Parallax

struct AppLayoutTests {
    @Test("tv idiom uses 60pt content inset and 4 poster columns")
    func tvMetrics() {
        #expect(AppLayout.contentHMargin(idiom: .tv) == 60)
        #expect(AppLayout.posterGridColumns(idiom: .tv) == 4)
        #expect(AppLayout.shelfTileWidth(idiom: .tv) == 220)
        #expect(AppLayout.libraryListColumns(idiom: .tv) == 1)
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
}