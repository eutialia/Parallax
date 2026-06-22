import SwiftUI

/// The shared layout shell for every settings + connect screen, so signed-in Settings, the per-server
/// detail, and the logged-out Connect flow all read as one surface — modelled on the tvOS Settings app.
///
/// - **tvOS:** ONLY the right-hand column of option pills (`SettingsGroup`/`SettingsListRow`). The app
///   icon AND the page label live in `TVSettingsRail` to the LEFT, OUTSIDE the NavigationStack: the
///   icon is pinned (anchored at the rail's vertical center) and the page label hangs BELOW it. Each
///   page hands its label up via `SettingsRailHeadingKey`, so the label changes on a push while the
///   icon never moves. Focus lands straight on the first pill (the rail is non-focusable).
/// - **iPhone / iPad:** a single centered column, brand on top then the groups (`AppLayout.settingsContentWidth`).
///
/// `#if os(tvOS)` is permitted here: this is the app target, and only the LAYOUT differs per platform
/// (the pills, groups, and flat focus contract are identical).
struct SettingsScaffold<Content: View>: View {
    /// Page title — e.g. "Settings" / a server name. On tvOS it's the label under the rail icon. Omit for none.
    var title: String? = nil
    /// Page subtitle — e.g. "Choose how to connect". On tvOS it's the label under the rail icon when there's
    /// no `title`. Omit for none.
    var brandSubtitle: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        #if os(tvOS)
        ScrollView {
            // The bleed lives INSIDE the scroll clip: the pills stay `tvSettingsColumnWidth`, and the
            // horizontal padding is slack the focus lift (`scaleEffect(1.03)` + shadow) grows into. The
            // ScrollView frame is column + bleed×2, so its clip never shaves the focused capsule's
            // rounded ends flat. (Padding OUTSIDE the ScrollView would inset the whole scroll, not give
            // the pills room — that clipped the focus platter.)
            VStack(alignment: .leading, spacing: Space.s26) { content }
                // Bound focus traversal to the pill column. The brand rail to the left is
                // non-focusable, so without this an up/left press past the edge pills can escape to the
                // tvOS tab bar (signed-in Settings is a TabView tab); the section keeps focus contained.
                .tvFocusSection()
                .frame(width: AppLayout.tvSettingsColumnWidth, alignment: .leading)
                .padding(.horizontal, AppLayout.tvSettingsColumnBleed)
                .padding(.top, AppLayout.tvSettingsColumnTopInset)
                .padding(.bottom, AppLayout.tvSettingsColumnBottomInset)
        }
        .frame(width: AppLayout.tvSettingsColumnWidth + AppLayout.tvSettingsColumnBleed * 2)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // Hand the page label up to the persistent rail, which draws it under the pinned icon.
        .preference(key: SettingsRailHeadingKey.self, value: title ?? brandSubtitle)
        // Hide the tvOS navigation bar. A pushed page's system `navigationTitle` reserves a top band
        // that shoves this column DOWN, so a titled page sat lower than a title-less one. Hiding it
        // anchors every scaffold page at the SAME top — and unlike `ignoresSafeArea(.top)` it does NOT
        // push content under the tvOS overscan.
        .toolbar(.hidden, for: .navigationBar)
        #else
        ScrollView {
            VStack(spacing: Space.s22) {
                brand
                    .frame(maxWidth: .infinity)
                    .padding(.bottom, Space.s8)
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
        // (tvOS is the exception: there `TVSettingsRail` wraps both the rail and this column, so it owns
        // the surface and the tvOS branch above paints none.)
        .background(Color.background.ignoresSafeArea())
        #endif
    }

    #if !os(tvOS)
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
    #endif
}

#if DEBUG && !os(tvOS)
/// Self-fill proof: NO external `.background` — the only thing that can paint the surface is the
/// scaffold's own `.background(Color.background)`. If this renders the dark charcoal (not pure black /
/// canvas default), the iPhone-tab regression is fixed. Mirrors the production host, which is a plain
/// tab with no presentation backing.
#Preview("Scaffold · self-fill (dark)") {
    SettingsScaffold(title: "Settings") {
        SettingsGroup(title: "Servers") {
            SettingsListRow(systemImage: "server.rack", title: "Living Room", subtitle: "jellyfin.local · alice")
        }
    }
    .preferredColorScheme(.dark)
}
#endif
