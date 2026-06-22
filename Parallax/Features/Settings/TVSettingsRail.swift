import SwiftUI

extension View {
    /// Wrap a settings/connect `NavigationStack` in the persistent tvOS brand rail: a large app icon
    /// pinned to the LEFT, OUTSIDE the stack, with the stack confined to the right column. Because the
    /// icon is a sibling of the stack (not a destination inside it), a push only animates the right
    /// column — the icon never re-renders or slides, so it stays visually pinned. The page label (each
    /// page's `title`/`brandSubtitle`, handed up via `SettingsRailHeadingKey`) hangs below the icon and
    /// changes per page. No-op on iOS/iPadOS, where each page carries its own brand-on-top.
    @ViewBuilder
    func tvSettingsBrandRail() -> some View {
        #if os(tvOS)
        TVSettingsRail { self }
        #else
        self
        #endif
    }
}

#if os(tvOS)
/// The page label the rail draws under its pinned icon — set by the active `SettingsScaffold` page and
/// read by `TVSettingsRail`. Last non-nil wins so the topmost page's label shows during a push.
struct SettingsRailHeadingKey: PreferenceKey {
    static let defaultValue: String? = nil
    static func reduce(value: inout String?, nextValue: () -> String?) {
        if let next = nextValue() { value = next }
    }
}

extension VerticalAlignment {
    /// Anchors the rail icon's CENTER to the rail's vertical center, so the label hanging below the icon
    /// extends DOWNWARD without shifting the icon up — the icon is the fixed anchor, everything attaches
    /// after it. (A plain centered VStack would re-center the icon+label group, lifting the icon when a
    /// label appears.)
    private enum RailIconCenter: AlignmentID {
        static func defaultValue(in d: ViewDimensions) -> CGFloat { d[VerticalAlignment.center] }
    }
    static let railIconCenter = VerticalAlignment(RailIconCenter.self)
}

/// The persistent left rail for the tvOS settings/connect surface. Draws the app icon ONCE — pinned and
/// anchored at the rail's vertical center (the device-icon idiom from Settings.app) — with the page
/// label hanging below it, beside the NavigationStack it hosts. Sizing the stack region to the shared
/// `tvSettingsColumnWidth` (+ bleed) keeps the push transition inside the right column so it never
/// slides under the icon. The icon is `.equatable()` and outside the stack, so neither focus moves nor
/// pushes can re-decode it (no flash, no travel).
struct TVSettingsRail<Content: View>: View {
    @ViewBuilder var content: Content

    @State private var heading: String?

    /// Read here and passed INTO `BrandTile` as a value (not read inside it) so the tile's
    /// `.equatable()` can't freeze a stale icon variant when the system appearance flips — see the note
    /// on `BrandTile.colorScheme`. Reading it here re-renders the rail on an appearance change.
    @Environment(\.colorScheme) private var colorScheme

    /// Enlarged now that the "Parallax" wordmark is gone — the icon alone carries the brand on the rail.
    private let iconSize: CGFloat = 280

    var body: some View {
        HStack(alignment: .center, spacing: 0) {
            brandRail
                .frame(maxWidth: .infinity)
            content
                .frame(width: AppLayout.tvSettingsColumnWidth + AppLayout.tvSettingsColumnBleed * 2)
                .frame(maxHeight: .infinity, alignment: .top)
                .onPreferenceChange(SettingsRailHeadingKey.self) { heading = $0 }
        }
        .padding(.horizontal, AppLayout.tvOverscanInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.background)
    }

    /// The icon (anchored at the rail's center) with the page label below it. The outer frame aligns on
    /// `.railIconCenter` — the icon's center — so the label grows downward and the icon never moves.
    private var brandRail: some View {
        VStack(spacing: Space.s30) {
            BrandTile(glyph: .brandIcon, size: iconSize, colorScheme: colorScheme)
                .equatable()
                .alignmentGuide(.railIconCenter) { $0[VerticalAlignment.center] }
            if let heading {
                Text(heading)
                    .font(.system(size: 26, weight: .medium))
                    .foregroundStyle(Color.secondaryLabel)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: iconSize + Space.s60 * 2)
                    // Distinct identity per label so a push crossfades the text (a same-view content
                    // change would snap) while the anchored icon stays put.
                    .id(heading)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity,
               alignment: Alignment(horizontal: .center, vertical: .railIconCenter))
        .animation(.easeInOut(duration: 0.2), value: heading)
    }
}

#if DEBUG
/// Focus-clip guard: previews can't drive the focus engine, so this paints the FOCUSED pill chrome
/// (white platter + `scaleEffect(1.03)` + shadow — matching `SettingsPill`) by hand inside the REAL
/// scaffold clip geometry. The middle pill is "focused"; its rounded ends must stay fully round, not
/// shaved flat. Proves `tvSettingsColumnBleed` gives the lift room inside the ScrollView's clip.
#Preview("tvOS rail · focus clip guard", traits: .fixedLayout(width: 1920, height: 1080)) {
    TVSettingsRail {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.s26) {
                ForEach(0..<3, id: \.self) { i in
                    Capsule(style: .continuous)
                        .fill(.white)
                        .frame(height: SettingsListRow.pillMinHeight)
                        .frame(maxWidth: .infinity)
                        .scaleEffect(i == 1 ? 1.03 : 1)
                        .shadow(color: .black.opacity(i == 1 ? 0.22 : 0), radius: i == 1 ? 11 : 0, y: i == 1 ? 6 : 0)
                }
            }
            .frame(width: AppLayout.tvSettingsColumnWidth, alignment: .leading)
            .padding(.horizontal, AppLayout.tvSettingsColumnBleed)
            .padding(.top, AppLayout.tvSettingsColumnTopInset)
            .padding(.bottom, AppLayout.tvSettingsColumnBottomInset)
        }
        .frame(width: AppLayout.tvSettingsColumnWidth + AppLayout.tvSettingsColumnBleed * 2)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
    .preferredColorScheme(.dark)
}

/// The login/connect look: a longer subtitle hanging under the anchored icon, credential pills on the
/// right. Confirms a multi-line label below the icon does NOT lift the icon (the anchor holds).
#Preview("tvOS settings rail · Login", traits: .fixedLayout(width: 1920, height: 1080)) {
    TVSettingsRail {
        NavigationStack {
            SettingsScaffold(brandSubtitle: "Sign in to your Jellyfin server") {
                SettingsGroup {
                    SettingsListRow(title: "Server", value: "jellyfin.local", action: {})
                    SettingsListRow(title: "Username", value: "alice", action: {})
                    SettingsListRow(title: "Password", value: "••••••••", action: {})
                    SettingsListRow(systemImage: "arrow.right", title: "Sign In", action: {})
                }
            }
        }
    }
    .preferredColorScheme(.dark)
}

/// The real composition: the pinned, anchored icon rail (with the page label below) hosting a
/// `NavigationStack` of one scaffold page. Render to confirm the icon sits centered-left, the label
/// hangs beneath it, and the pills fill the right column.
#Preview("tvOS settings rail · Settings", traits: .fixedLayout(width: 1920, height: 1080)) {
    TVSettingsRail {
        NavigationStack {
            SettingsScaffold(title: "Settings") {
                SettingsGroup(title: "Servers") {
                    SettingsListRow(
                        title: "Living Room",
                        subtitle: "jellyfin.local · alice",
                        status: SettingsRowStatus(text: "Active", isOn: true),
                        accessory: .chevron,
                        action: {}
                    )
                    SettingsListRow(systemImage: "plus", title: "Add Server", action: {})
                }
                SettingsGroup(title: "Storage") {
                    SettingsListRow(systemImage: "photo.stack", title: "Thumbnail Cache", value: "128 MB")
                }
            }
        }
    }
    .preferredColorScheme(.dark)
}
#endif
#endif
