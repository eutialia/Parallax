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
    /// Horizontal inset for primary scrollable content (grids, rows, sections).
    static let contentHMargin: CGFloat = 20

    /// Leading inset for custom chrome inside the iPadOS sidebar — today just the account
    /// footer. The `.tabViewSidebarBottomBar` closure is handed the full sidebar width with
    /// no row-pill inset, and the system never exposes the inset it gives its own tab rows,
    /// so custom content can't inherit it. This is the single knob that lines such content
    /// up under the row glyphs: matched to the system rows by eye, tune here if the
    /// on-device gap drifts. Any future sidebar header/footer should use this same value.
    static let sidebarLeadingInset: CGFloat = 30
}
