import SwiftUI
import ParallaxJellyfin
import ParallaxCore
import ParallaxFeatures

/// The iPhone Library tab's shell: renders `AppModel.libraries` — the same resolution the iPad
/// sidebar and tvOS focus root show, loaded by the root — and owns the load / empty / failure
/// states. `LibraryListView` below is pure presentation.
///
/// There is no separate SMB-only list: an SMB-only config is just a resolution with no Jellyfin
/// groups and no Favorites card, so one view covers both.
struct LibraryHostView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let libraries = app.libraries
        Group {
            if !libraries.groups.isEmpty {
                LibraryListView(
                    groups: libraries.groups,
                    showsFavorites: libraries.hasJellyfinSource,
                    // A PARTIAL failure used to be silent: the full-screen error below only shows
                    // when every source failed, so with two servers one unreachable server just
                    // read as "I have fewer libraries than I remember". Naming it in-place is the
                    // same answer the Favorites wall gives with its per-section failure row.
                    unreachableServers: libraries.failedSourceNames
                )
                .navigationTitle("Library")
                // Note: no `.navigationSubtitle(session.serverName)`. It named a single server
                // above a list that already mixed sources, and with several servers there is no
                // one name to put there. Server identity now rides the per-server section headers
                // inside the list, which is where it actually applies.
            } else if libraries.isResolving {
                LibraryListLoadingPlaceholder()
                    .navigationTitle("Library")
            } else if !libraries.failedSourceIDs.isEmpty {
                // Every source that could have contributed failed to list — offline, not empty.
                StatusStateView.failure(
                    "Couldn't load libraries",
                    message: "Parallax couldn't reach your servers. Check your connection and try again."
                )
                .navigationTitle("Library")
            } else {
                StatusStateView(
                    title: "No libraries",
                    systemImage: "rectangle.stack.badge.xmark",
                    message: "Add a Jellyfin or SMB source in Settings to browse your library."
                )
                .navigationTitle("Library")
            }
        }
        .screenFloor()
    }
}
