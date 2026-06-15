import SwiftUI
import ParallaxJellyfin
import ParallaxCore

struct LibraryHostView: View {
    @Environment(AppDependencies.self) private var deps
    @Environment(AppRouter.self) private var router
    /// The active Jellyfin session: drives the Jellyfin VM + its load/error states. The iPhone
    /// host stays Jellyfin-anchored — SMB is additive, not a standalone source here, so with no
    /// session we keep the existing "No active server" empty state even when `smbEntries` is
    /// non-empty (SMB-only users are out of scope — known limitation).
    @State private var session: Session?
    /// SMB libraries to surface alongside the Jellyfin collections, resolved SMB-only
    /// (`jellyfinSession: nil`). Empty when no SMB servers are configured (or all failed).
    @State private var smbEntries: [LibraryEntry] = []
    @State private var isResolvingSource = true

    var body: some View {
        Group {
            if let session {
                LibraryListView(session: session, smbEntries: smbEntries)
                    .navigationTitle("Library")
                    // Server name sits under the title (was a truncated "cort…"
                    // caption crammed into the top-left). Becomes a source-switcher
                    // Menu in v2 when SMB/Local sources arrive.
                    #if !os(tvOS)
                    .navigationSubtitle(session.serverName)
                    #endif
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
        // Keyed on the reload token (not `activeServerID`): a Jellyfin switch (token's id part)
        // AND an SMB add/remove (token's revision part) both rebuild the SMB entries — mirrors how
        // RootTabView/FocusRootView refresh their merged lists, so the iPhone card-list picks up an
        // added SMB server without a relaunch.
        .task(id: router.libraryReloadToken) {
            guard router.activeServerID != nil else { return }
            defer { isResolvingSource = false }
            session = await deps.serverStore.active
            // SMB-only entries (nil session): the Jellyfin libraries come from LibraryListView's
            // own VM, so MergedLibrary here contributes only the SMB cards.
            smbEntries = await MergedLibrary.entries(
                jellyfinSession: nil,
                smbServers: await deps.serverStore.servers,
                repoFactory: deps.mediaRepoFactory
            )
        }
    }
}
