import SwiftUI

/// Shared scaffold for the settings add-server forms: a top-aligned `ScrollView` that caps content at
/// the settings reading width, centers it, and insets it. The Add Jellyfin Server and Add SMB Server
/// pages share this one layout so they read identically (the goal: matching add-server UI) instead of
/// each re-deriving the same padding + width. The Jellyfin form used to ride the auth card's
/// upper-third bias + tighter 444 measure, which left an empty gap once its brand mark moved to the
/// Settings root — this lines it up at the top with the SMB form.
struct SettingsFormScaffold<Content: View>: View {
    var width: CGFloat = AppLayout.settingsContentWidth
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            content
                .padding(Space.s18)
                .frame(maxWidth: width)
                .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
    }
}
