import ParallaxJellyfin
import ParallaxCore

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

    /// Transparent logo for hero foreground — movies and series only.
    var heroLogoRef: ImageRef? {
        switch self {
        case .movie(let m): return m.imageRef(.logo)
        case .series(let s): return s.imageRef(.logo)
        case .episode: return nil
        }
    }

    /// Text title over `.primary` poster art (logo is often baked in); logo over landscape art.
    func heroUsesLogoTitle(regularWidth: Bool) -> Bool {
        heroArtwork(regularWidth: regularWidth).kind != .primary
    }

    /// Compact year/runtime line when the hero has no overview blurb.
    var heroMetadataLine: String? {
        switch self {
        case .movie(let m):
            var parts: [String] = []
            if let y = m.year { parts.append(String(y)) }
            if let r = m.runtime { parts.append("\(Int(r.components.seconds / 60)) min") }
            return parts.isEmpty ? nil : parts.joined(separator: " · ")
        case .series(let s): return s.year.map(String.init)
        case .episode:
            // Episodes never headline a hero — they're only hidden Play targets.
            return nil
        }
    }
}
