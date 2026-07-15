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

    /// Resting height for the tvOS **library-header chip** (the genre/sort pills + their matching
    /// loading skeleton in `LibraryGridView`) — the only consumer. The 10-foot `.headline` type
    /// (~38pt vs ~17pt on iOS) needs more vertical room than the iOS metrics. This governs ONLY that
    /// chip; the hero/detail action row AND the full-width form CTAs both ride
    /// `ActionRow.controlHeight(.tv)` (62, handoff-spec'd) so the control families read at one height.
    /// This library-header chip stays its own knob. Pairs with `contentHMargin(.tv)` for the gutter.
    static let tvControlHeight: CGFloat = 64

    /// Max content width for the settings / form surfaces (the Settings tab's server + storage cards,
    /// the SMB add form). tvOS widens it for the same reason as `tvControlHeight`: the 10-foot type
    /// renders ~1.5× the iOS size, so the iOS measure crammed the rows into wrapping, oversized lines.
    /// Centered via a trailing `.frame(maxWidth: .infinity)` at each call site. One knob per family so
    /// the surfaces can't drift apart. The logged-out Connect flow now shares this same scaffold.
    #if os(tvOS)
    static let settingsContentWidth: CGFloat = 680
    /// Per-server detail (`ServerSettingsView`) — the widest reading measure of the settings family.
    static let settingsDetailWidth: CGFloat = 780
    /// The centered settings/connect column on tvOS — the handoff's `.tv-col` (792px on its 1280 canvas
    /// = 61.9% of width → 1188pt on the 1920 screen). The native `.sidebarAdaptable` tab collapses into
    /// the "Settings" pill in the left gutter and the build tag sits in the right gutter, both flanking
    /// this column. Shared by `SettingsScaffold` (lays the rows out at this width). Was a cramped 560 —
    /// the "squashed into the center" bug — back when a pinned left brand rail stole half the screen.
    static let tvSettingsColumnWidth: CGFloat = 1188
    /// Horizontal slack INSIDE the scroll clip on each side of the column so a focused row's platter +
    /// shadow isn't shaved flat by the ScrollView's clip. The column stays `tvSettingsColumnWidth` wide —
    /// only the scroll frame grows.
    static let tvSettingsColumnBleed: CGFloat = 24
    /// Top inset above the first section — clears the native collapsed-sidebar "Settings" pill (which
    /// the system parks at the top-leading overscan). Matches the handoff's `.tv-col top:140px` (×1.5 =
    /// 210pt absolute), minus the tvOS top safe area the ScrollView already reserves.
    static let tvSettingsColumnTopInset: CGFloat = 150
    /// Bottom inset below the last pill: overscan clearance plus room for its focus lift before the
    /// scroll edge. Shared with the focus-clip-guard preview alongside `tvSettingsColumnTopInset`.
    static let tvSettingsColumnBottomInset: CGFloat = 80
    #else
    static let settingsContentWidth: CGFloat = 560
    static let settingsDetailWidth: CGFloat = 720
    #endif

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

    /// Column count for a wall of 16:9 landscape tiles — the SMB folder browser's subfolders +
    /// video thumbnails. Denser than `libraryListColumns` (which sizes the big top-level library
    /// BANNERS, one-/two-up): a browsed video is a small frame-grab, so it wants the same 4-up
    /// density the SMB library grid used before the share-hierarchy refactor folded it into the
    /// banner grid (the "only two columns" regression).
    static func landscapeGridColumns(idiom: AppIdiom) -> Int {
        switch idiom {
        case .compact: 2
        case .regular: 4
        case .tv: 4
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