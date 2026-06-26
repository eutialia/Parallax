import SwiftUI
import ParallaxJellyfin
import ParallaxCore

struct LibraryHostView: View {
    @Environment(AppDependencies.self) private var deps
    @Environment(AppRouter.self) private var router
    /// The active Jellyfin session: drives the Jellyfin VM + its load/error states. With a session
    /// the host shows the merged Jellyfin + SMB list (`LibraryListView`); with none but ≥1 SMB
    /// source it shows the SMB-only list (`SMBLibraryListView`).
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
            } else if !smbEntries.isEmpty {
                // SMB-only config: no Jellyfin session, so browse the SMB libraries directly.
                SMBLibraryListView(entries: smbEntries)
                    .navigationTitle("Library")
            } else if isResolvingSource {
                LibraryListLoadingPlaceholder()
                    .navigationTitle("Library")
            } else {
                StatusStateView(
                    title: "No libraries",
                    systemImage: "rectangle.stack.badge.xmark",
                    message: "Add a Jellyfin or SMB source in Settings to browse your library."
                )
            }
        }
        .screenFloor()
        // Keyed on the reload token (not `activeServerID`): a Jellyfin switch (token's id part)
        // AND an SMB add/remove (token's revision part) both rebuild the SMB entries — mirrors how
        // RootTabView/FocusRootView refresh their merged lists, so the iPhone card-list picks up an
        // added SMB server without a relaunch.
        .task(id: router.libraryReloadToken) {
            // Clear, don't just early-return: a future caller that drops the last source without a
            // remount must not leave a stale session/SMB list rendered (mirrors RootTabView's task).
            guard router.hasAnySource else { session = nil; smbEntries = []; isResolvingSource = false; return }
            defer { isResolvingSource = false }
            // SMB-only entries (nil session): the Jellyfin libraries come from LibraryListView's
            // own VM, so MergedLibrary here contributes only the SMB cards. Capture then commit
            // under a cancellation check so a token change mid-flight can't land a stale snapshot.
            let active = await deps.serverStore.active
            let merged = await MergedLibrary.entries(
                jellyfinSession: nil,
                smbServers: await deps.serverStore.servers,
                jellyfinRepo: deps.mediaRepoFactory
            )
            guard !Task.isCancelled else { return }
            session = active
            smbEntries = merged
        }
    }
}
