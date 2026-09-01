import ParallaxCore
import SwiftUI

// The app-target half of the artwork accent: which artwork to read, how the extracted HSB
// becomes a `Color`, and what the bar paints when there isn't one. The pipeline itself —
// decode, vote, normalize — is `ParallaxCore.ArtworkAccent`, pure CoreGraphics/ImageIO with no
// SwiftUI in sight.

extension Color {
    init(_ accent: AccentHSB) {
        self.init(hue: accent.hue, saturation: accent.saturation, brightness: accent.brightness)
    }
}

extension ItemDetail {
    /// The artwork the accent is derived from. The poster for a movie; for an episode the still
    /// first, falling back through season to series art — the same `stillFirstImageRef` ladder
    /// the shelves and detail pages already show, so the bar's hue matches the picture the user
    /// pressed Play on. Series/season never play.
    nonisolated var accentImageRef: ImageRef? {
        switch self {
        case .movie(let detail): detail.movie.imageRef(.primary)
        case .episode(let detail): detail.episode.stillFirstImageRef
        case .series, .season: nil
        }
    }
}

extension PlayerViewModel {
    /// The colour every PROVISIONAL element of the scrub bar is painted in — the ghost handle,
    /// the span band, the comet, the settle pulse, the arrival bloom. White until the artwork's
    /// accent lands (and forever, if it never does), which is exactly the pre-accent look.
    /// Reaches the bar through `\.scrubAccent`, set once on the player root.
    var scrubAccent: Color { accentHSB.map(Color.init) ?? .white }
}
