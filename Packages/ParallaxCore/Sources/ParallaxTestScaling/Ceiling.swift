/// An anti-hang ceiling counted in the time its waiter got to run.
///
/// A frozen CI runner wakes every timer that came due during the freeze at once when it thaws:
/// CI logs show pure value tests reported at 19-70 s. A wall-clock deadline is spent by then,
/// so the waiter gives up on its first turn after the thaw, before the work it waits for has
/// had one. `Ceiling` counts the time between checks instead, each lap capped at 100 ms, so a
/// freeze costs one lap.
///
/// A runner that is slow on every lap gets the same discount, so the wall clock still bounds
/// the wait at four times `limit`: a genuine hang fails at its own line instead of riding out
/// the suite's time limit.
public struct Ceiling: Sendable {
    private static let maxLap: Duration = .milliseconds(100)
    private static let wallFactor = 4

    private let limit: Duration
    private let now: @Sendable () -> ContinuousClock.Instant
    private let start: ContinuousClock.Instant
    private var lapStart: ContinuousClock.Instant
    private var spent: Duration = .zero

    init(_ limit: Duration, now: @escaping @Sendable () -> ContinuousClock.Instant = { .now }) {
        self.limit = limit
        self.now = now
        start = now()
        lapStart = start
    }

    /// Whether any of the ceiling is left, counting the lap since the previous call.
    mutating func remains() -> Bool {
        let now = now()
        spent += min(lapStart.duration(to: now), Self.maxLap)
        lapStart = now
        return spent < limit && start.duration(to: now) < limit * Self.wallFactor
    }

    /// Re-reads `condition` every `interval` until it holds or the ceiling is spent, and returns
    /// whether it held. Runs on the caller's actor, so a `@MainActor` condition stays isolated.
    public nonisolated(nonsending) static func poll(
        _ limit: Duration,
        every interval: Duration = .milliseconds(20),
        until condition: () async throws -> Bool
    ) async throws -> Bool {
        var ceiling = Ceiling(limit)
        while try await !condition() {
            guard ceiling.remains() else { return false }
            try await Task.sleep(for: interval)
        }
        return true
    }

    /// Returns once `limit` is spent: the timeout side of a race against the awaited work.
    public static func expire(_ limit: Duration) async throws {
        _ = try await poll(limit) { false }
    }
}
