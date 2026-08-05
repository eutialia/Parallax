import SwiftUI

/// The one margin story for every media WALL — the SMB browse levels, the Jellyfin library grid,
/// the Favorites wall, and the loading skeletons that stand in for them. They must inset
/// identically or the skeleton→loaded swap visibly shifts, so the geometry lives here once:
///
/// - Horizontal: `AppLayout.contentHMargin` on every platform.
/// - tvOS vertical: the 40pt focus-lift overscan INSIDE the scroll clip (a focused tile's lift at
///   the wall's edge needs room to grow; the title-safe-margin approach, not a disabled clip).
/// - iOS vertical: whatever the surface passes (`iosVertical`) — the walls differ (12pt for the
///   SMB browser, 0 for the poster grids, whose nav bar provides the breathing room).
///
/// `tvRootChromeBypass` is the tvOS TAB-ROOT treatment: a `.sidebarAdaptable` root keeps the
/// collapsed sidebar pill, and the system reserves a full-width 60pt safe-area band for that
/// chrome on top of the 60pt title-safe inset (120pt total — measured in-sim, tvOS 26). Screens
/// pushed on the tab's stack hide the chrome (`tvHidesTabSidebar()`) and get the bare 60pt, so a
/// root wall rested 60pt lower than the identical pushed wall. Hiding the tab bar at a root is
/// refused by the system, and no native "keep the bar, drop its inset" API exists (SDK-verified:
/// `SafeAreaRegions` is only `container`/`keyboard`/`all`, every safe-area modifier is additive) —
/// so the bypass drops the container's top inset entirely and rebuilds the title-safe margin by
/// hand from `AppLayout.tvTitleSafeVInset`. The pill floats above the scrolling wall, which is
/// the documented model for tvOS top chrome ("the position of the tab bar remains fixed while
/// content scrolls underneath it" — UIKit `tabBarObservedScrollView` docs; HIG Layout: sidebars
/// and tab bars "appear on top of content rather than on the same plane").
///
/// Pass `true` only on surfaces tvOS hosts as tab ROOTS (the Jellyfin grid and Favorites are
/// only ever roots there; SMB passes `path.path.isEmpty`). Inert off tvOS: iPhone pushes these
/// same views with normal nav-bar insets, and the iPad sidebar is a leading-edge overlay with no
/// top band.
extension View {
    /// See the file header above for the full geometry story. Covers the SMB browse, Jellyfin
    /// library, and Favorites walls + their skeletons. Deliberately NOT the search surfaces:
    /// the tvOS `.searchable` screen ignores the safe area entirely and clears the pill via
    /// `AppLayout.tvSearchTopClearance` — a different chrome problem with its own knob.
    func mediaWallContentMargins(iosVertical: CGFloat = 0, tvRootChromeBypass: Bool = false) -> some View {
        modifier(MediaWallContentMargins(iosVertical: iosVertical, tvRootChromeBypass: tvRootChromeBypass))
    }
}

private struct MediaWallContentMargins: ViewModifier {
    let iosVertical: CGFloat
    let tvRootChromeBypass: Bool

    @Environment(\.appIdiom) private var idiom

    func body(content: Content) -> some View {
        content
            .contentMargins(.horizontal, AppLayout.contentHMargin(idiom: idiom), for: .scrollContent)
            .contentMargins(.top, topMargin, for: .scrollContent)
            .contentMargins(.bottom, idiom == .tv ? Space.s40 : iosVertical, for: .scrollContent)
            .ignoresSafeArea(.container, edges: bypassEdges)
    }

    private var topMargin: CGFloat {
        guard idiom == .tv else { return iosVertical }
        return tvRootChromeBypass ? AppLayout.tvTitleSafeVInset + Space.s40 : Space.s40
    }

    private var bypassEdges: Edge.Set {
        idiom == .tv && tvRootChromeBypass ? .top : []
    }
}
