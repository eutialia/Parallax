import SwiftUI
import ParallaxJellyfin

struct LibraryHostView: View {
    @Environment(AppDependencies.self) private var deps
    @State private var source: LibrarySource?

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
            } else {
                ContentUnavailableView(
                    "No active server",
                    systemImage: "server.rack",
                    description: Text("Sign in from the Servers tab.")
                )
            }
        }
        .task {
            if let session = await deps.serverStore.active {
                source = .jellyfin(session)
            }
        }
    }
}
