import CoreGraphics

/// Shared layout metrics — one source of truth for content insets so every
/// scrollable surface uses the same leading/trailing gap. Before this, Home
/// rows and the Library grid hardcoded `16` while the List (system-managed)
/// and the detail screens used `20`, so the gap between the floating iPadOS 26
/// sidebar and content jumped from screen to screen (device smoke-test #5).
///
/// The List gets its inset from the system (it's sidebar-aware); the custom
/// scroll views don't, so they apply this value — via `.contentMargins` where
/// possible so it cooperates with the safe area instead of being measured from
/// the raw screen edge. If the on-device gap still needs tuning, this is the
/// single knob.
enum AppLayout {
    /// Leading inset for custom chrome inside the iPadOS sidebar — today the settings
    /// bottom bar. The `.tabViewSidebarBottomBar` closure is handed the full sidebar width with
    /// no row-pill inset, and the system never exposes the inset it gives its own tab rows,
    /// so custom content can't inherit it. This is the single knob that lines such content
    /// up under the row glyphs: matched to the system rows by eye, tune here if the
    /// on-device gap drifts. Any future sidebar header/footer should use this same value.
    static let sidebarLeadingInset: CGFloat = 30

    /// tvOS title-safe horizontal inset (≈ the system overscan margin, ~90pt on the 1920×1080
    /// canvas). Hero screens drop the system horizontal safe area via `heroScreenSafeArea()` so
    /// artwork bleeds to the physical edges, then re-add THIS to non-hero content via
    /// `tvContentInset()`. It stacks with each component's own `contentHMargin`, reconstructing
    /// the exact gutter the safe area used to provide — so shelves/body don't move, only the
    /// hero goes full-bleed. tvOS reserves it on all four edges and clips focusable content that
    /// strays outside, so cards must stay inside it. (Apple HIG "Designing for tvOS" / WWDC19.)
    static let tvOverscanInset: CGFloat = 90

    /// Resting height for a tvOS button/control. The 10-foot `.headline` type (~38pt vs ~17pt
    /// on iOS) needs far more vertical room than the iOS metrics, so every tvOS pill floors at
    /// this — the single knob for control height across the play pill, glass circles, form CTAs,
    /// and the player's error buttons. Pairs with `contentHMargin(.tv)` for the horizontal gutter.
    static let tvControlHeight: CGFloat = 64

    /// Compact is 16 and regular is 20 — the system's own layout margins, which is
    /// also exactly where the nav bar parks its trailing glass circles (measured in
    /// the "Sort button in toolbar" ruler preview: circle trailing edge at 16pt
    /// compact / 20pt regular). Anything else leaves the library's sort button
    /// visibly off the grid's trailing edge.
    static func contentHMargin(idiom: AppIdiom) -> CGFloat {
        switch idiom {
        case .compact: 16
        case .regular: 20
        case .tv: 40
        }
    }

    static func posterGridColumnSpacing(idiom: AppIdiom) -> CGFloat {
        switch idiom {
        case .compact, .regular: Space.s12
        // 40pt is Apple's canonical focusable-tile spacing on tvOS (WWDC24 "Migrate
        // your TVML app to SwiftUI"): wide enough that a focused poster's lift/specular
        // doesn't crowd its neighbours.
        case .tv: Space.s40
        }
    }

    /// Rows are deliberately wider than columns on iOS (s16 vs s12): each tile hangs a
    /// caption below the art, so the vertical gap needs the extra breathing room.
    static func posterGridRowSpacing(idiom: AppIdiom) -> CGFloat {
        switch idiom {
        case .compact, .regular: Space.s16
        case .tv: Space.s40
        }
    }

    static func posterGridColumns(idiom: AppIdiom) -> Int {
        switch idiom {
        case .compact: 3
        case .regular: 5
        case .tv: 6
        }
    }

    /// Column count for a LANDSCAPE (16:9) library grid — the SMB sources, whose tiles are video
    /// frame-grabs rather than portrait posters. Deliberately fewer columns than
    /// `posterGridColumns`: a 16:9 tile is far wider than a 2:3 poster at the same column width, so
    /// reusing the poster count would leave each landscape tile short and cramped. These keep a
    /// landscape tile a comfortable size on each idiom (tune here if the on-device density drifts).
    static func landscapeGridColumns(idiom: AppIdiom) -> Int {
        switch idiom {
        case .compact: 2
        case .regular: 4
        case .tv: 4
        }
    }

    static func shelfTileWidth(idiom: AppIdiom) -> CGFloat {
        switch idiom {
        case .compact, .regular: HomeShelf.tileWidth
        case .tv: 220
        }
    }

    static func libraryListColumns(idiom: AppIdiom) -> Int {
        switch idiom {
        case .compact: 1
        case .regular: 2
        // The TV has the width for a denser wall of 16:9 library banners — one-up
        // wasted most of the screen and made each card oversized.
        case .tv: 3
        }
    }

    /// Inter-card gap (both axes) for the library-banner grid. On tvOS the cards take the same
    /// 1.1× focus lift as posters, so they need the same 40pt canonical spacing — at 12pt a
    /// focused 16:9 banner's lift grew wider than the gap and overlapped its neighbour. iPhone/iPad
    /// have no focus lift, so they keep the tight 12pt wall.
    static func libraryListSpacing(idiom: AppIdiom) -> CGFloat {
        switch idiom {
        case .compact, .regular: Space.s12
        case .tv: Space.s40
        }
    }

    static func searchPosterColumns(idiom: AppIdiom) -> Int {
        switch idiom {
        case .compact: 3
        case .regular, .tv: 4
        }
    }

    static func searchLandscapeColumns(idiom: AppIdiom) -> Int {
        switch idiom {
        case .compact: 2
        case .regular, .tv: 3
        }
    }

    static func seriesEpisodeTileWidth(idiom: AppIdiom) -> CGFloat {
        switch idiom {
        case .compact, .regular: SeriesShelf.episodeTileWidth
        case .tv: 280
        }
    }
}