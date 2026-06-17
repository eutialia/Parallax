import SwiftUI
import ParallaxJellyfin

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

extension View {
    /// The `LibraryEntry` drill-down destination: an entry carries its own source, so the grid
    /// builds the right repo and plays on tap. A distinct value type from the Jellyfin
    /// `MediaCollection` destination, so the two never collide. Shared by every screen that lists
    /// SMB libraries.
    func smbLibraryDestination() -> some View {
        navigationDestination(for: LibraryEntry.self) { entry in
            LibraryGridView(collection: entry.collection, source: entry.source)
        }
    }
}
