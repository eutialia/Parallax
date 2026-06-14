import ParallaxJellyfin
import ParallaxCore

extension Item {
    /// Poster-ratio (2:3) shelf art — season folder, series poster, and movie
    /// primary share Jellyfin's usual poster aspect. Episodes fall back to still.
    var homeShelfImageRef: ImageRef? { homeShelfArtwork.ref }

    private var homeShelfArtwork: (ref: ImageRef?, kind: ImageKind) {
        switch self {
        case .movie(let m):
            return (m.imageRef(.primary), .primary)
        case .series(let s):
            return (s.imageRef(.primary), .primary)
        case .episode(let e):
            if let ref = e.seasonImageRef { return (ref, ref.kind) }
            if let ref = e.seriesImageRef { return (ref, ref.kind) }
            return (e.imageRef(.primary), .primary)
        }
    }
}