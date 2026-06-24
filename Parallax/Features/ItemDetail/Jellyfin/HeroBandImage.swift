import SwiftUI
import ParallaxJellyfin
import ParallaxCore

/// The detail-header artwork — 16:9 landscape on iPad/tvOS, 2:3 poster on iPhone — clipped to the
/// band by `MediaImage`'s `.fill`. Raw artwork only: `HeroBand` composites the legibility veil over
/// it and owns the iPad sidebar extension (applied to the artwork+veil composite so the mirror
/// carries the veil), so the `artwork` slot needs nothing more than `HeroBandImage(...)`. The Home
/// carousel hands its slot a differently-clipped, transformed `CrossfadeArtwork` instead.
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
    }
}
