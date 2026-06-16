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

    @State private var artwork: ArtworkSource = .none

    var body: some View {
        MediaTile(
            title: item.displayTitle,
            artwork: artwork,
            progress: nil,
            watched: .init(item),
            aspectRatio: MediaImage.poster,
            maxImageWidth: 600
        )
        .task(id: item.id) {
            artwork = await provider.artwork(for: item, ref: ref)
        }
    }
}
