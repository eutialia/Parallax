import ParallaxJellyfin

extension Item {
    /// Hero band artwork — landscape 16:9 on iPad regular width; 2:3 `.primary` poster on iPhone.
    func heroArtwork(regularWidth: Bool) -> (ref: ImageRef?, kind: ImageKind) {
        if regularWidth { return (landscapeImageRef, landscapeImageKind) }
        switch self {
        case .movie(let m): return (m.imageRef(.primary), .primary)
        case .series(let s): return (s.imageRef(.primary), .primary)
        case .episode(let e): return (e.imageRef(.primary), .primary)
        }
    }
}