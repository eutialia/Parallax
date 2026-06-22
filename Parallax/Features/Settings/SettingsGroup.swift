import SwiftUI

/// One section of a settings/connect screen: an optional uppercase header above a vertical stack of
/// STANDALONE pills (each `SettingsListRow`/`SettingsRowLabel` draws its own pill). This is the tvOS
/// Settings.app idiom — separated pills with gaps between them, NOT rows fused into a grouped-list
/// container. No background, no hairlines; the spacing IS the separation.
struct SettingsGroup<Content: View>: View {
    var title: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s8) {
            if let title {
                Text(title)
                    .font(.sectionHeader)
                    .textCase(.uppercase)
                    .foregroundStyle(Color.secondaryLabel)
                    .padding(.horizontal, Space.s8)
                    .padding(.bottom, 2)
            }
            VStack(spacing: Space.s8) { content }
        }
    }
}
