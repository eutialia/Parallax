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

    @State private var artwork: ArtworkSource = .none

    var body: some View {
        MediaTile(
            title: item.displayTitle,
            artwork: artwork,
            progress: nil,
            watched: .init(item),
            aspectRatio: aspectRatio,
            maxImageWidth: 600
        )
        // Pin the enclosing Button's hit region to the visible tile rect. The load-bearing half of
        // the tap fix is `allowsHitTesting(false)` on the artwork in `MediaImage` (a 16:9 frame
        // aspect-fills a 2:3 box and overflows; left interactive that overflow stole taps from the
        // Button and neighbouring cells). This `contentShape` is the matching hit-region pin (as on
        // LibraryCard/FavoritesCard) so the tappable area tracks the rounded rect, not the raw frame.
        .contentShape(.rect(cornerRadius: Radius.tile))
        .task(id: item.id) {
            artwork = await provider.artwork(for: item, ref: ref)
        }
    }
}
