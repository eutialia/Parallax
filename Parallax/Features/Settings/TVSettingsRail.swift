import SwiftUI

extension View {
    /// Apply the tvOS settings/connect chrome to a settings `NavigationStack`: paint the screen floor
    /// and float the build tag in the top-right gutter (handoff `.tv-build`, root only). There is NO
    /// custom heading pill — the native `.sidebarAdaptable` tab collapses into the "Settings" pill in
    /// the top-left gutter on its own, so drawing one here just duplicated it. No-op on iOS/iPadOS,
    /// where each page carries its own nav chrome.
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
/// The build tag shown top-right (handoff `.tv-build`) — set ONLY by the settings root, so it shows on
/// the root and vanishes on pushed sub-screens (which don't set it).
struct SettingsBuildTagKey: PreferenceKey {
    static let defaultValue: String? = nil
    static func reduce(value: inout String?, nextValue: () -> String?) {
        if let next = nextValue() { value = next }
    }
}

/// The tvOS settings/connect chrome: the hosted `NavigationStack` full-bleed on the screen floor, with
/// the build tag floated in the top-right gutter. The screen's own collapsed-sidebar pill (the native
/// `.sidebarAdaptable` tab name) provides the "Settings" identity in the top-left gutter — this view
/// deliberately draws no pill of its own. The centered column lives inside `SettingsScaffold`; the two
/// gutters that flank it carry the native pill (left) and this build tag (right).
struct TVSettingsRail<Content: View>: View {
    @ViewBuilder var content: Content

    @State private var buildTag: String?

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(Color.background)
            .overlay(alignment: .topTrailing) { buildTagView }
            .onPreferenceChange(SettingsBuildTagKey.self) { buildTag = $0 }
    }

    @ViewBuilder
    private var buildTagView: some View {
        if let buildTag {
            Text(buildTag)
                // Handoff `.tv-build`: 18px on the 1280 canvas → 27pt at 1920, semibold, tertiary ink.
                .font(.system(size: 27, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(Color.tertiaryLabel)
                .padding(.top, Space.s12)
                .padding(.trailing, AppLayout.tvOverscanInset)
                .transition(.opacity)
                .animation(.easeInOut(duration: 0.2), value: buildTag)
        }
    }
}

#if DEBUG
/// The settings root under the chrome: the centered column with the build tag floated top-right (the
/// native "Settings" pill that would sit top-left is system-drawn and absent from this isolated preview).
/// Render to confirm the column centers and the build tag clears the overscan.
#Preview("tvOS settings chrome · Settings", traits: .fixedLayout(width: 1920, height: 1080)) {
    TVSettingsRail {
        NavigationStack {
            SettingsScaffold(showsBrand: false) {
                SettingsGroup(title: "Servers") {
                    SettingsListRow(
                        systemImage: "server.rack",
                        iconSize: 22,
                        title: "home-jellyfin",
                        subtitle: "Jellyfin · jellyfin.example.lan",
                        accessory: .chevron,
                        action: {}
                    )
                    SettingsListRow(systemImage: "plus", title: "Add Server", isAccent: true, action: {})
                }
                SettingsGroup(title: "Storage", footer: "Cached artwork and thumbnails.") {
                    SettingsListRow(systemImage: "photo.on.rectangle", title: "Thumbnail Cache", value: "7.7 MB")
                }
            }
            .preference(key: SettingsBuildTagKey.self, value: "Parallax 1.0 (142)")
        }
    }
    .preferredColorScheme(.dark)
}
#endif
#endif
