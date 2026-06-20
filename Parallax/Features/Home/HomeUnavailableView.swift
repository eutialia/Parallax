import SwiftUI

/// Home's no-Jellyfin state. The Home feed — hero, Continue Watching, Next Up,
/// recommendations — is a Jellyfin feature, so a config with only SMB / local /
/// other non-Jellyfin sources has nothing to populate it. Rather than spin an
/// endless skeleton, Home shows this; the libraries themselves stay reachable
/// from the Library section.
///
/// Reachable on both platforms: iOS `RootTabView` and tvOS `FocusRootView` render an SMB-only
/// config's Home, and `HomeView` routes here for `destination == .home` with no Jellyfin session.
/// The libraries themselves stay reachable from the sidebar / Library section.
struct HomeUnavailableView: View {
    var body: some View {
        StatusStateView(
            title: "No Home Feed",
            systemImage: "house",
            message: "Home highlights like Continue Watching and Next Up come from a Jellyfin server. Browse your other libraries from the Library section."
        )
    }
}

#Preview("Home unavailable · dark") {
    HomeUnavailableView()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.background)
        .preferredColorScheme(.dark)
}

#Preview("Home unavailable · light") {
    HomeUnavailableView()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.background)
        .preferredColorScheme(.light)
}
