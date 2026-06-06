import SwiftUI
import ParallaxJellyfin

/// Full-bleed hero-band artwork for detail headers — 16:9 landscape on iPad, 2:3 poster on iPhone.
struct HeroBandImage: View {
    let landscapeRef: ImageRef?
    let posterRef: ImageRef?
    let session: Session
    let regularWidth: Bool

    var body: some View {
        JellyfinImage(
            ref: regularWidth ? landscapeRef : posterRef,
            kind: regularWidth ? .backdrop(index: 0) : .primary,
            session: session,
            maxWidth: 1600,
            aspectRatio: HeroMetrics.bandAspectRatio(regularWidth: regularWidth),
            style: .fill
        )
    }
}