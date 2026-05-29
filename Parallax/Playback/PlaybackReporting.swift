import Foundation
import ParallaxJellyfin

/// App-side seam over the three Jellyfin progress-report calls. PlayerViewModel
/// depends on this protocol (not the concrete PlaybackInfoService actor) so the
/// integration test can inject a recording stub.
///
/// PlaybackInfoService.reportProgress takes a `now:` clock argument (4c, Task
/// 4c.5) for deterministic throttle tests; this protocol omits it and the
/// conformance bridges with a real wall-clock value. reportStart/reportStopped
/// match the actor's signatures exactly.
protocol PlaybackReporting: Sendable {
    func reportStart(_ beat: ProgressBeat) async
    func reportProgress(_ beat: ProgressBeat) async
    func reportStopped(_ beat: ProgressBeat) async
}

extension PlaybackInfoService: PlaybackReporting {
    /// Bridge to the actor's `reportProgress(_:now:)` using monotonic uptime as
    /// the clock — the service only uses `now` for throttle deltas, so any
    /// steadily-increasing seconds value is correct in production.
    public func reportProgress(_ beat: ProgressBeat) async {
        await reportProgress(beat, now: ProcessInfo.processInfo.systemUptime)
    }
}
