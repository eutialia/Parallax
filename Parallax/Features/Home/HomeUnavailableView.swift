import SwiftUI

/// Home's no-Jellyfin state. The Home feed — hero, Continue Watching, Next Up,
/// recommendations — is a Jellyfin feature, so a config with only SMB / local /
/// other non-Jellyfin sources has nothing to populate it. Rather than spin an
/// endless skeleton, Home shows this; the libraries themselves stay reachable
/// from the Library section.
///
/// Not reachable in the shipping app yet: every tab root still gates on a Jellyfin
/// `activeServerID`, so an SMB-only config lands on login (see
/// `project-smb-only-routing-blocked`). `HomeView` already routes here for
/// `destination == .home` with no Jellyfin session, so it lights up the instant
/// that routing is unblocked — no extra wiring.
struct HomeUnavailableView: View {
    var body: some View {
        ContentUnavailableView {
            Label("No Home Feed", systemImage: "house")
        } description: {
            Text("Home highlights like Continue Watching and Next Up come from a Jellyfin server. Browse your other libraries from the Library section.")
        }
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
