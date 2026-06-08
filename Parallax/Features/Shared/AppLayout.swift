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

    static func contentHMargin(idiom: AppIdiom) -> CGFloat {
        switch idiom {
        case .compact: 18
        case .regular: 20
        case .tv: 40
        }
    }

    static func posterGridColumnSpacing(idiom: AppIdiom) -> CGFloat {
        switch idiom {
        case .compact, .regular: Space.s12
        case .tv: 24
        }
    }

    static func posterGridRowSpacing(idiom: AppIdiom) -> CGFloat {
        switch idiom {
        case .compact, .regular: 16
        case .tv: 28
        }
    }

    static func posterGridColumns(idiom: AppIdiom) -> Int {
        switch idiom {
        case .compact: 3
        case .regular: 5
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
        case .compact, .tv: 1
        case .regular: 2
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