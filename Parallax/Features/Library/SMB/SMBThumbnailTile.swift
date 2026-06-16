import SwiftUI
import ParallaxCore

/// SMB grid cell: the same poster chrome as the Jellyfin `MediaTile`, but its artwork resolves
/// lazily — a frame-grab generated + cached on first appearance by `MediaArtworkProvider` (an SMB
/// file carries no server poster). Until one exists it shows the same gray placeholder as a
/// missing Jellyfin poster.
///
/// The `.task(id:)` is the whole concurrency story: SwiftUI starts it when the cell scrolls into
/// the `LazyVGrid` and cancels it on scroll-off or item-identity change. That cancellation
/// propagates through the provider's single-permit gate into `VLCThumbnailer`, so a scrolled-past
/// tile gives up the one generation slot to a still-visible one instead of holding it behind a
/// 20s demux.
struct SMBThumbnailTile: View {
    let item: Item
    let ref: SMBServerRef
    let provider: MediaArtworkProvider
    /// 16:9 by default — an SMB tile is a video frame-grab, which reads naturally wide. The grid
    /// passes the source-derived shape so the tile, its column count, and the cached thumbnail's
    /// crop all agree (a 16:9 frame forced into a 2:3 box overflowed and stole the cell's taps).
    var aspectRatio: CGFloat = MediaImage.landscape

    @State private var artwork: MediaArtwork = .none

    var body: some View {
        MediaTile(
            title: item.displayTitle,
            artwork: artwork.source,
            watched: .init(item),
            aspectRatio: aspectRatio,
            maxImageWidth: 600,
            metadata: .init(secondary: secondaryLine)
        )
        // Pin the enclosing Button's hit region. The load-bearing half of the tap fix is
        // `allowsHitTesting(false)` on the artwork in `MediaImage` (a 16:9 frame aspect-fills a 2:3
        // box and overflows; left interactive that overflow stole taps from the Button and
        // neighbouring cells). This `contentShape` pins the tappable area to the laid-out tile —
        // here the whole VStack (thumbnail + metadata row), so the filename row is tappable too, not
        // just the artwork (unlike LibraryCard/FavoritesCard, which wrap a single artwork rect).
        .contentShape(.rect(cornerRadius: Radius.tile))
        .task(id: item.id) {
            artwork = await provider.artwork(for: item, ref: ref)
        }
    }

    /// Duration once the frame-grab has resolved it (the better line), else the file size we
    /// already carry from the directory listing — so the row is never empty while a thumbnail
    /// generates, and upgrades from "1.4 GB" to "1h 23m" when it lands. A duration that formats to
    /// "" (a sub-1-second clip) falls through to the size rather than blanking the line.
    private var secondaryLine: String? {
        if let label = artwork.duration?.compactRuntimeLabel, !label.isEmpty {
            return label
        }
        return fileSizeLabel
    }

    private var fileSizeLabel: String? {
        guard case .movie(let movie) = item, let size = movie.size, size > 0 else { return nil }
        return size.formatted(.byteCount(style: .file))
    }
}
