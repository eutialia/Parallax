import ParallaxJellyfin
import ParallaxCore

extension Item {
    /// 16:9 landscape artwork for Home rows and the hero: prefer `.thumb`, then a
    /// `.backdrop`, then fall back to `.primary` (an episode's `.primary` is already a
    /// 16:9 still). Shared by `HomeView` and `HomeHeroCarousel` so the row tiles and the
    /// hero sample the same image (matching artwork keeps the zoom transition seamless).
    var landscapeImageRef: ImageRef? { landscapeArtwork.ref }

    /// The `ImageKind` matching `landscapeImageRef`, so the image cache key stays in sync.
    var landscapeImageKind: ImageKind { landscapeArtwork.kind }

    /// Single source for the ref/kind pair so the two can never disagree (a mismatched
    /// pair would poison the image cache key). Movies/series share the thumb→backdrop→
    /// primary priority; an episode's `.primary` is the 16:9 still.
    private var landscapeArtwork: (ref: ImageRef?, kind: ImageKind) {
        switch self {
        case .movie(let m):
            return Self.pick(m.imageRef(.thumb), m.imageRef(.backdrop(index: 0)), m.imageRef(.primary))
        case .series(let s):
            return Self.pick(s.imageRef(.thumb), s.imageRef(.backdrop(index: 0)), s.imageRef(.primary))
        case .episode(let e):
            return (e.imageRef(.primary), .primary)
        }
    }

    private static func pick(_ thumb: ImageRef?, _ backdrop: ImageRef?, _ primary: ImageRef?)
        -> (ref: ImageRef?, kind: ImageKind) {
        if let thumb { return (thumb, .thumb) }
        if let backdrop { return (backdrop, .backdrop(index: 0)) }
        return (primary, .primary)
    }
}
