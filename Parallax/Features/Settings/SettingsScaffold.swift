import SwiftUI

/// The shared layout shell for every settings + connect screen, so signed-in Settings, the per-server
/// detail, and the logged-out Connect flow all read as one surface — modelled on the tvOS Settings app.
///
/// - **tvOS:** a single CENTERED column of grouped rows (`SettingsGroup`/`SettingsListRow`) at
///   `AppLayout.tvSettingsColumnWidth`. Signed-in, the "Settings" identity comes from the native
///   collapsed-sidebar pill the `.sidebarAdaptable` tab parks in the top-left gutter — this scaffold
///   draws no pill of its own. Focus lands straight on the first row.
/// - **iPhone / iPad:** a single centered column, brand on top then the groups (`AppLayout.settingsContentWidth`).
///
/// `#if os(tvOS)` is permitted here: this is the app target, and only the LAYOUT differs per platform
/// (the groups, rows, and flat focus contract are identical). Screen titles are owned per-screen — the
/// nav bar on iOS, a `FormIntroHeader` / hero on tvOS — not by this scaffold.
struct SettingsScaffold<Content: View>: View {
    /// Page subtitle under the "Parallax" brand lockup — e.g. "Choose how to connect" (first-run). Only
    /// shown when `showsBrand` is true. Omit for none.
    var brandSubtitle: String? = nil
    /// Whether the surface leads with the "Parallax" brand lockup. First-run Connect wants it (it's the
    /// screen's identity on BOTH platforms — on tvOS there's no sidebar pill when logged out). Signed-in
    /// Settings and the detail/form screens suppress it: the native pill / subject hero / `FormIntroHeader`
    /// own their identity instead, so the app brand doesn't sit redundantly above them.
    var showsBrand: Bool = true
    /// Whether the tvOS column wraps in a `ScrollView`. Defaults true — every ordinary settings
    /// screen (grouped rows) wants the scaffold to scroll as normal. Set false for a screen that
    /// owns its OWN height-bounded, internally-scrollable focus region — e.g. `LicenseTextView`'s
    /// `FocusableScrollText`. Nesting that kind of region inside this scaffold's unbounded
    /// `ScrollView` proposes infinite height, so the inner view grows to fit all its content
    /// instead of clipping to the screen, and has nothing left to scroll (the exact bug
    /// `FocusableScrollText` exists to fix). iOS always scrolls via native `UIScrollView` touch and
    /// ignores this flag — its branch below is unaffected.
    var scrolls: Bool = true
    @ViewBuilder var content: Content

    var body: some View {
        #if os(tvOS)
        Group {
            if scrolls {
                ScrollView {
                    tvColumn
                }
            } else {
                tvColumn
            }
        }
        .frame(width: AppLayout.tvSettingsColumnWidth + AppLayout.tvSettingsColumnBleed * 2)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // Hide the tvOS navigation bar. A pushed page's system `navigationTitle` reserves a top band
        // that shoves this column DOWN, so a titled page sat lower than a title-less one. Hiding it
        // anchors every scaffold page at the SAME top.
        .toolbarVisibility(.hidden, for: .navigationBar)
        // Deterministic top for every scaffold host: the signed-in Settings TAB ROOT keeps the
        // sidebar chrome, whose safe-area band (60pt over title-safe) shoved its column 60pt below
        // the SAME scaffold on pushed pages and logged-out Connect (chrome-less, title-safe only).
        // Drop the container's top inset and rebuild it by hand in `tvColumn`'s top padding — all
        // three hosts land the first section at the identical absolute y. Same mechanism as the
        // media walls (`mediaWallContentMargins`); see `AppLayout.tvTitleSafeVInset`.
        .ignoresSafeArea(.container, edges: .top)
        #else
        ScrollView {
            VStack(spacing: Space.s22) {
                if showsBrand {
                    brand
                        .frame(maxWidth: .infinity)
                        .padding(.bottom, Space.s8)
                }
                content
            }
            .padding(Space.s18)
            .frame(maxWidth: AppLayout.settingsContentWidth)
            .frame(maxWidth: .infinity)
        }
        // The scaffold owns the iOS surface color — it's the one shell every settings/connect page
        // (Settings, server detail, Connect, the pushed Login/SMB forms) wraps, so painting here covers
        // them all from a single place. `SettingsView`'s `.presentationBackground` backs only the iPad
        // SHEET container; embedded as a plain tab on iPhone there's no presentation to back, so without
        // this the transparent scroll fell through to the system's pure-black `systemBackground`.
        // (tvOS is the exception: signed-in, `RootView` paints the single floor behind the whole
        // tab host, and logged-out Connect paints via `tvSettingsFloor()` — so the tvOS branch
        // above paints none.)
        .background(BackgroundField.style.ignoresSafeArea())
        #endif
    }

    #if os(tvOS)
    // The bleed lives INSIDE the scroll clip: the pills stay `tvSettingsColumnWidth`, and the
    // horizontal padding is slack the focus lift (`scaleEffect(1.03)` + shadow) grows into. The
    // ScrollView frame is column + bleed×2, so its clip never shaves the focused capsule's
    // rounded ends flat. (Padding OUTSIDE the ScrollView would inset the whole scroll, not give
    // the pills room — that clipped the focus platter.) When `scrolls` is false this column sits
    // directly under the bounded outer frame instead — its `content` gets the screen's real height
    // proposal, so a flexible child (`.frame(maxHeight: .infinity)`) can claim the remaining space.
    private var tvColumn: some View {
        VStack(alignment: .leading, spacing: Space.s26) {
            // First-run Connect sets `showsBrand` — and on tvOS it's logged out, so there's NO
            // collapsed-sidebar pill to name the screen; the brand lockup is its only identity.
            // Signed-in Settings + the detail/form screens pass `showsBrand: false` (native pill /
            // hero / FormIntroHeader own their identity), so this stays first-run-only.
            if showsBrand {
                brand
                    .frame(maxWidth: .infinity)
                    .padding(.bottom, Space.s8)
            }
            content
        }
            // Bound focus traversal to the column. Without this an up/left press past the edge rows
            // can escape to the tvOS tab bar (signed-in Settings is a TabView tab); the section keeps
            // focus contained until the user deliberately steps out to the collapsed sidebar.
            .tvFocusSection()
            .frame(width: AppLayout.tvSettingsColumnWidth, alignment: .leading)
            .padding(.horizontal, AppLayout.tvSettingsColumnBleed)
            // Title-safe rebuilt by hand (the scaffold ignores the container's top inset — see
            // `body`), so this is an ABSOLUTE screen offset: 60 title-safe + 150 = 210pt, the
            // handoff's `.tv-col top` on every host, root or pushed.
            .padding(.top, AppLayout.tvTitleSafeVInset + AppLayout.tvSettingsColumnTopInset)
            .padding(.bottom, AppLayout.tvSettingsColumnBottomInset)
    }
    #endif

    private var brand: some View {
        VStack(spacing: Space.s14) {
            BrandMark(glyph: .brandIcon, title: "Parallax")
            if let brandSubtitle {
                Text(brandSubtitle)
                    .font(.rowSubtitle)
                    .foregroundStyle(Color.secondaryLabel)
                    .multilineTextAlignment(.center)
            }
        }
    }
}

#if DEBUG && !os(tvOS)
/// Self-fill proof: NO external `.background` — the only thing that can paint the surface is the
/// scaffold's own `.background(Color.background)`. If this renders the dark charcoal (not pure black /
/// canvas default), the iPhone-tab regression is fixed. Mirrors the production host, which is a plain
/// tab with no presentation backing.
#Preview("Scaffold · self-fill (dark)") {
    SettingsScaffold {
        SettingsGroup(title: "Servers") {
            SettingsListRow(image: "JellyfinGlyph", iconSize: 22, title: "Living Room", subtitle: "jellyfin.local · alice")
        }
    }
    .preferredColorScheme(.dark)
}
#endif
