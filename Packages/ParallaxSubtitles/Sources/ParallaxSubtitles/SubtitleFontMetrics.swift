import CoreGraphics
import CoreText
import Foundation

/// Font facts callers need to reason about how libass will SIZE text.
public enum SubtitleFontMetrics {

    /// The divisor libass' VSFilter-style sizing applies to `family`: the OS/2
    /// win box (usWinAscent+usWinDescent) over the em. A font declaring a 1.16
    /// box renders an em at 86% of the requested size — so a caller that wants
    /// "the size that RENDERS equals the size I tuned" must multiply its scale
    /// by this factor. 1 when the family (or its metrics) can't be resolved.
    public static func emBoxFactor(forFamily family: String) -> Double {
        let font = CTFontCreateWithName(family as CFString, 12, nil)
        guard let url = CTFontCopyAttribute(font, kCTFontURLAttribute) as? URL else { return 1 }
        return emBoxFactor(forFace: url)
    }

    /// Same ratio, from a face already resolved to a file URL — the path callers
    /// that already have one (from a `CTFont` they hold, not a family name) take,
    /// so they don't pay for a second `CTFontCreateWithName` + attribute lookup.
    public static func emBoxFactor(forFace url: URL) -> Double {
        guard let metrics = SystemGlyphFont.faceMetrics(of: url), metrics.unitsPerEm > 0 else { return 1 }
        let box = Double(metrics.winAscent) + Double(metrics.winDescent)
        return box > 0 ? box / Double(metrics.unitsPerEm) : 1
    }
}
