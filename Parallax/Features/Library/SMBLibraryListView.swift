import SwiftUI
import ParallaxJellyfin
import ParallaxCore

/// The iPhone Library tab for an SMB-only configuration (no Jellyfin session). Renders just
/// the configured SMB libraries in the same banner grid as `LibraryListView`, drilling into
/// the source-aware, play-on-tap SMB grid via the `LibraryEntry` navigation value.
///
/// The merged Jellyfin + SMB case stays in `LibraryListView`, which anchors on a live session
/// (it owns the Jellyfin VM + Favorites); this is its session-less sibling — no Jellyfin VM,
/// no Favorites (a Jellyfin-only concept). The SMB cell + drill-down are shared (`SMBLibraryCell`
/// / `smbLibraryDestination()`) so this list and `LibraryListView`'s SMB section can't diverge.
struct SMBLibraryListView: View {
    let entries: [LibraryEntry]
    @Environment(\.appIdiom) private var idiom

    var body: some View {
        ScrollView {
            let cols = AppLayout.libraryListColumns(idiom: idiom)
            let gap = AppLayout.libraryListSpacing(idiom: idiom)
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: gap), count: cols),
                spacing: gap
            ) {
                ForEach(entries) { SMBLibraryCell(entry: $0) }
            }
            .padding(AppLayout.contentHMargin(idiom: idiom))
        }
        // Don't clip a focused card's lift at the scroll bounds.
        .tvScrollClipDisabled()
        .smbLibraryDestination()
    }
}

/// One SMB library banner: a `LibraryCard` that drills into the source-aware, play-on-tap SMB grid.
/// Shared by `SMBLibraryListView` (the SMB-only list) and `LibraryListView` (the merged list's SMB
/// section) so the card chrome + navigation value live in one place.
struct SMBLibraryCell: View {
    let entry: LibraryEntry

    var body: some View {
        NavigationLink(value: entry) { LibraryCard(smb: entry.collection) }
            .tvPosterButton()
    }
}

/// The destination view for a `LibraryEntry`, branching by source: an SMB share opens the folder
/// browser (`SMBBrowseView` at the share root), a Jellyfin collection opens the poster grid. The ONE
/// place this branch lives — shared by the iPhone list drill-down (`smbLibraryDestination`) and the
/// iPad/tvOS sidebar tabs (`RootTabView` / `FocusRootView`) so they can't dispatch a source two ways.
@ViewBuilder
func libraryEntryDestination(for entry: LibraryEntry) -> some View {
    switch entry.source {
    case .smb(let ref):
        SMBBrowseView(path: SMBBrowsePath(ref: ref, share: entry.collection.name, path: ""))
    case .jellyfin(let session):
        // Title is owned by the grid (from the collection) so the iPhone Library-list
        // drill-down and the direct sidebar tab show it identically.
        LibraryGridView(collection: entry.collection, session: session)
    }
}

extension View {
    /// The `LibraryEntry` drill-down destination for screens that push entries as navigation values
    /// (the merged + SMB-only iPhone lists). A distinct value type from the Jellyfin
    /// `MediaCollection` destination, so the two never collide.
    func smbLibraryDestination() -> some View {
        navigationDestination(for: LibraryEntry.self) { libraryEntryDestination(for: $0) }
    }
}
