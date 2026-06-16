import ParallaxCore

extension Item {
    /// Poster-ratio (2:3) shelf art — season folder, series poster, and movie
    /// primary share Jellyfin's usual poster aspect. Episodes fall back to still.
    var homeShelfImageRef: ImageRef? {
        switch self {
        case .movie(let m): m.imageRef(.primary)
        case .series(let s): s.imageRef(.primary)
        case .episode(let e): e.seasonImageRef ?? e.seriesImageRef ?? e.imageRef(.primary)
        }
    }
}