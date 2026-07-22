import SwiftUI
import ParallaxCore
import ParallaxFileBrowse

/// SMB grid cell: the same poster chrome as the Jellyfin `MediaTile`, but its artwork resolves
/// lazily — a strict sidecar image or a frame-grab, generated + cached on first appearance by
/// `MediaArtworkProvider` (an SMB file carries no server poster). Until one exists it shows the same
/// gray placeholder as a missing Jellyfin poster.
///
/// The `.task(id:)` starts when the cell scrolls into the `LazyVGrid` and is cancelled on scroll-off
/// or item-identity change — but that cancellation now abandons only this tile's AWAIT of the shared,
/// provider-owned generation, never the generation itself (which runs to completion; a folder-wide
/// prefetch wants every key anyway). So a scrolled-past tile costs nothing extra; the work it kicked
/// off still finishes and lands in the cache for the next appearance.
struct SMBThumbnailTile: View {
    let item: Item
    let ref: SMBServerRef
    let provider: MediaArtworkProvider
    /// The strict sidecar-image match for this item (from the browse listing), or nil. Threaded into
    /// the provider so the sidecar tier can short-circuit the frame-grab.
    var sidecar: SMBDirectoryEntry?
    /// 16:9 by default — an SMB tile is a video frame-grab, which reads naturally wide. The grid
    /// passes the source-derived shape so the tile, its column count, and the cached thumbnail's
    /// crop all agree (a 16:9 frame forced into a 2:3 box overflowed and stole the cell's taps).
    var aspectRatio: CGFloat = MediaImage.landscape

    @State private var artwork: MediaArtwork = .none

    var body: some View {
        // The contained MediaTile (single view): the modifiers below must stay single-target — the
        // lockup form is Group-transparent on tvOS, so `.task` would fetch the frame-grab twice and
        // `contentShape` would split the hit region. A tvOS `.borderless` button label wanting the
        // native caption nudge uses `lockup()` below instead, which keeps the task on the thumbnail
        // sibling only.
        mediaTile(artwork: artwork)
        // Pin the enclosing Button's hit region. The load-bearing half of the tap fix is
        // `allowsHitTesting(false)` on the artwork in `MediaImage` (a 16:9 frame aspect-fills a 2:3
        // box and overflows; left interactive that overflow stole taps from the Button and
        // neighbouring cells). This `contentShape` pins the tappable area to the laid-out tile —
        // here the whole VStack (thumbnail + metadata row), so the filename row is tappable too, not
        // just the artwork (unlike LibraryCard/FavoritesCard, which wrap a single artwork rect).
        .contentShape(.rect(cornerRadius: Radius.tile))
        .task(id: item.id) {
            artwork = await provider.artwork(for: item, ref: ref, sidecar: sidecar)
        }
    }

    /// The `.borderless` button-label form: on tvOS the thumbnail and metadata row resolve as
    /// SIBLING label children, so the native lockup slides the filename clear of the lifted
    /// artwork (the same fix the search episode tiles got — a contained VStack suppresses the
    /// nudge and the focused frame lands on the text). iOS resolves to the contained form above.
    /// Use ONLY as a Button label (tuple-transparent on tvOS; see `MediaTile.lockup()`).
    func lockup() -> Lockup { Lockup(tile: self) }

    struct Lockup: View {
        let tile: SMBThumbnailTile
        /// The lockup owns its OWN artwork state: the contained tile's `@State` belongs to a view
        /// that is never installed on this path, and the frame-grab task must ride the thumbnail
        /// sibling (via `MediaTile.lockup(thumbnailTaskID:thumbnailTask:)`), not the tuple.
        @State private var artwork: MediaArtwork = .none

        var body: some View {
            #if os(tvOS)
            tile.mediaTile(artwork: artwork).lockup(thumbnailTaskID: tile.item.id) {
                artwork = await tile.provider.artwork(for: tile.item, ref: tile.ref, sidecar: tile.sidecar)
            }
            #else
            tile
            #endif
        }
    }

    /// The tile content for a given artwork state — shared by the contained body (which feeds its
    /// own `@State`) and the tvOS `Lockup` (which feeds its sibling-loaded state).
    fileprivate func mediaTile(artwork: MediaArtwork) -> MediaTile {
        MediaTile(
            title: item.displayTitle,
            artwork: artwork.source,
            watched: .init(item),
            aspectRatio: aspectRatio,
            maxImageWidth: 600,
            metadata: .init(leading: fileSizeLabel, trailing: durationLabel(artwork))
        )
    }

    /// File size from the directory listing — the leading detail, available immediately, so the row
    /// is never empty while a thumbnail generates.
    private var fileSizeLabel: String? {
        guard case .movie(let movie) = item, let size = movie.size, size > 0 else { return nil }
        return size.formatted(.byteCount(style: .file))
    }

    /// The clip's duration once the frame-grab resolves it — the trailing detail, sitting beside the
    /// file size rather than replacing it. nil (no trailing detail) for a cached thumbnail with no
    /// `.dur` sidecar yet, or a sub-1-second clip whose label is empty.
    private func durationLabel(_ artwork: MediaArtwork) -> String? {
        guard let label = artwork.duration?.compactRuntimeLabel, !label.isEmpty else { return nil }
        return label
    }
}
