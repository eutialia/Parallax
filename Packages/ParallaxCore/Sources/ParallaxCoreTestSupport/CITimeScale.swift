import Foundation

/// Scales the suites' anti-hang ceilings on CI.
///
/// Network- and decode-shaped tests bound every operation with a deadline so a genuine
/// hang fails its own test instead of wedging the run. Those deadlines are calibrated
/// for dev hardware — and oversubscribed CI runners blow through them while the code
/// under test behaves correctly: CI logs show a bridge test PASSING with exact bytes
/// after 23.9s, and `URLError -1001` failures on tests measured at 83s wall-clock
/// against a 10s client timeout. A tripped ceiling there reports a hang that never
/// happened, and the flake blocked three PR merges in two days.
///
/// Scale the ceiling, never the assertion: multiply anti-hang bounds by `factor`; keep
/// correctness expectations untouched. Local runs stay tight at ×1. CI reaches the
/// simulator test host as `CI` via `TEST_RUNNER_CI` in ci.yml (plain shell env never
/// crosses into simulator processes) — the same probe the live-VLC-decode suite uses.
public enum CITimeScale {
    /// ×12 on CI — above the worst measured overshoot (83s against a 10s ceiling,
    /// ×8.3) with margin, while a genuine hang still fails in minutes, inside the
    /// job's 20-minute bound. ×1 locally.
    public static let factor: Double =
        ProcessInfo.processInfo.environment["CI"] == nil ? 1 : 12

    /// A `Duration` ceiling of `seconds` on dev hardware, scaled for CI.
    public static func seconds(_ seconds: Double) -> Duration {
        .seconds(seconds * factor)
    }

    /// A `TimeInterval` ceiling of `seconds` on dev hardware, scaled for CI
    /// (`URLSessionConfiguration` timeouts).
    public static func interval(_ seconds: TimeInterval) -> TimeInterval {
        seconds * factor
    }
}
