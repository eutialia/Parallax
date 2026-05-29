import Foundation
import CoreMedia

/// The auto-resume rule from the Phase 4 spec: resume from the saved position
/// unless we're under 5s in (treat as "start over") or past 95% complete (treat
/// as "finished"). Pure arithmetic for deterministic testing.
enum ResumePolicy {
    static let ticksPerSecond: Double = 10_000_000
    static let floorSeconds: Double = 5
    static let ceilingFraction: Double = 0.95

    /// `positionTicks` is `UserItemData.playbackPositionTicks` (Int64). `runtime`
    /// is the parent item's `Duration?` (Movie/Episode `runtime`).
    static func resumeStartTime(positionTicks: Int64, runtime: Duration?) -> CMTime? {
        let seconds = Double(positionTicks) / ticksPerSecond
        guard seconds >= floorSeconds else { return nil }
        guard let runtime else { return nil }
        let runtimeSeconds = Double(runtime.components.seconds)
            + Double(runtime.components.attoseconds) / 1e18
        guard runtimeSeconds > 0 else { return nil }
        guard seconds <= ceilingFraction * runtimeSeconds else { return nil }
        return CMTime(seconds: seconds, preferredTimescale: 600)
    }
}
