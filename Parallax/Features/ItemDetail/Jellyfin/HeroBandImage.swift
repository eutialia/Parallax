import SwiftUI
import ParallaxJellyfin
import ParallaxCore

/// The detail-header artwork — 16:9 landscape on iPad/tvOS, 2:3 poster on iPhone — clipped to the
/// band by `MediaImage`'s `.fill`. Raw artwork only: the hero mounts (`heroBackdrop` on
/// iPhone/iPad, `HeroBand` on tvOS) own everything else — the bottom treatments layered above,
/// and the iPad sidebar extension, which samples exactly this bare picture (treatments are never
/// in the mirrored raster) — so the `artwork` slot needs nothing more than `HeroBandImage(...)`.
/// The Home carousel hands its slot a differently-clipped, transformed `CrossfadeArtwork` instead.
struct HeroBandImage: View {
    let landscapeRef: ImageRef?
    let posterRef: ImageRef?
    let session: Session
    let regularWidth: Bool

    /// The ref the band is actually showing (idiom pick). Exposed so detail call sites feed the SAME
    /// image's blurHash to `HeroBand(floorBleedHash:)` without restating the pick.
    var displayedRef: ImageRef? { regularWidth ? landscapeRef : posterRef }

    var body: some View {
        MediaImage(
            jellyfin: displayedRef,
            session: session,
            maxWidth: 1600,
            aspectRatio: HeroMetrics.bandAspectRatio(regularWidth: regularWidth),
            style: .fill
        )
    }
}
