import SwiftUI
import ParallaxCore

/// The destination view for a `LibraryEntry`, branching by source: an SMB share opens the folder
/// browser (`SMBBrowseView` at the share root), a Jellyfin collection opens the poster grid. The ONE
/// place this branch lives — shared by the iPhone card list's drill-down (`smbLibraryDestination`)
/// and the iPad/tvOS sidebar tabs (`RootTabView` / `FocusRootView`), so they can't dispatch a source
/// two ways. It's also why every list pushes a `LibraryEntry` rather than a bare `MediaCollection`:
/// the entry carries WHICH server the collection came from, which a multi-server list can't infer.
@ViewBuilder
func libraryEntryDestination(for entry: LibraryEntry) -> some View {
    switch entry.source {
    case .smb(let ref):
        SMBBrowseView(path: SMBBrowsePath(ref: ref, share: entry.collection.name, path: ""))
    case .jellyfin(let session):
        // Title is owned by the grid (from the collection) so the iPhone card-list drill-down and
        // the direct sidebar tab show it identically.
        LibraryGridView(collection: entry.collection, session: session)
    }
}

extension View {
    /// The `LibraryEntry` drill-down destination for screens that push entries as navigation values
    /// (the iPhone card list). A distinct value type from the Jellyfin `MediaCollection` destination
    /// used inside the grids, so the two never collide.
    func smbLibraryDestination() -> some View {
        navigationDestination(for: LibraryEntry.self) { libraryEntryDestination(for: $0) }
    }
}
