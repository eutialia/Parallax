import SwiftUI
import ParallaxJellyfin

struct LibraryHostView: View {
    @Environment(AppDependencies.self) private var deps
    @Environment(AppRouter.self) private var router
    @State private var source: LibrarySource?
    @State private var isResolvingSource = true

    var body: some View {
        Group {
            if let source {
                switch source {
                case .jellyfin(let session):
                    JellyfinLibraryListView(session: session)
                        .navigationTitle("Library")
                        // Server name sits under the title (was a truncated "cort…"
                        // caption crammed into the top-left). Becomes a source-switcher
                        // Menu in v2 when SMB/Local sources arrive.
                        .navigationSubtitle(source.displayName)
                }
            } else if isResolvingSource {
                LibraryListLoadingPlaceholder()
                    .navigationTitle("Library")
            } else {
                ContentUnavailableView(
                    "No active server",
                    systemImage: "server.rack",
                    description: Text("Sign in to a Jellyfin server to browse your library.")
                )
            }
        }
        .task(id: router.activeServerID) {
            guard router.activeServerID != nil else { return }
            defer { isResolvingSource = false }
            if let session = await deps.serverStore.active {
                source = .jellyfin(session)
            }
        }
    }
}
