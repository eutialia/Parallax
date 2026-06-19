import SwiftUI
import ParallaxJellyfin
import ParallaxCore

/// The complete detail-header artwork layer — 16:9 landscape on iPad/tvOS, 2:3 poster on iPhone —
/// clipped to the band (by `MediaImage`'s `.fill`) and carrying the iPad sidebar extension effect,
/// so `HeroBand`'s `artwork` slot needs nothing more than `HeroBandImage(...)`. No scrim: legibility
/// lives on the foreground (`HeroBottomFade` / `HeroCornerFade`), so the artwork reads clean. The
/// Home carousel hands its slot a differently-clipped, transformed `CrossfadeArtwork` instead.
struct HeroBandImage: View {
    let landscapeRef: ImageRef?
    let posterRef: ImageRef?
    let session: Session
    let regularWidth: Bool

    var body: some View {
        MediaImage(
            jellyfin: regularWidth ? landscapeRef : posterRef,
            session: session,
            maxWidth: 1600,
            aspectRatio: HeroMetrics.bandAspectRatio(regularWidth: regularWidth),
            style: .fill
        )
        .heroBandExtension(regularWidth: regularWidth)
    }
}
