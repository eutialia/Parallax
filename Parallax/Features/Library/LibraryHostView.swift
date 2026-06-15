import SwiftUI
import ParallaxJellyfin
import ParallaxCore

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
                    LibraryListView(session: session)
                        .navigationTitle("Library")
                        // Server name sits under the title (was a truncated "cort…"
                        // caption crammed into the top-left). Becomes a source-switcher
                        // Menu in v2 when SMB/Local sources arrive.
                        #if !os(tvOS)
                        .navigationSubtitle(source.displayName)
                        #endif
                case .smb:
                    // SMB libraries are presented from the merged sidebar (wired in the
                    // merged-library task); this single-source iPhone host never resolves
                    // a .smb source yet.
                    EmptyView()
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
        .screenFloor()
        .task(id: router.activeServerID) {
            guard router.activeServerID != nil else { return }
            defer { isResolvingSource = false }
            if let session = await deps.serverStore.active {
                source = .jellyfin(session)
            }
        }
    }
}
