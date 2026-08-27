import Foundation

/// Font facts callers need to reason about how libass will SIZE text.
public enum SubtitleFontMetrics {

    /// The divisor libass' VSFilter-style sizing applies to `family`: the OS/2
    /// win box (usWinAscent+usWinDescent) over the em, read from the bundled
    /// face carrying that family. A font declaring a 1.45 box renders an em at
    /// 69% of the requested size — so a caller that wants "the size that
    /// RENDERS equals the size I tuned" must multiply its scale by this factor.
    /// 1 for a family the bundle doesn't carry, which libass resolves through
    /// `default_family` anyway.
    public static func emBoxFactor(forFamily family: String) -> Double {
        guard let metrics = SubtitleFontBundle.metrics(forFamily: family), metrics.unitsPerEm > 0 else {
            return 1
        }
        let box = Double(metrics.winAscent) + Double(metrics.winDescent)
        return box > 0 ? box / Double(metrics.unitsPerEm) : 1
    }
}
