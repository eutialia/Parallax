import Foundation

public extension Duration {
    /// The duration as fractional seconds (`1.5s` → `1.5`). The canonical
    /// seconds-plus-attoseconds conversion — call this instead of hand-rolling
    /// `Double(components.seconds) + Double(components.attoseconds) / 1e18` at use sites.
    var fractionalSeconds: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }

    /// Compact runtime label for media tiles — `"1h 23m"`, `"23m"`, or `"<1m"` for a sub-minute
    /// clip. Empty string when the duration is zero or negative (nothing to show).
    ///
    /// Distinct from `DetailMetadata`'s `"X min"` long form: a tile under a 16:9 thumbnail needs
    /// the tight hour+minute shape, not a spelled-out minutes count that wraps.
    var compactRuntimeLabel: String {
        let totalSeconds = components.seconds
        guard totalSeconds > 0 else { return "" }
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        if hours > 0 {
            return minutes > 0 ? "\(hours)h \(minutes)m" : "\(hours)h"
        }
        if minutes > 0 { return "\(minutes)m" }
        return "<1m"
    }
}
