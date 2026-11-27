/// An anti-hang ceiling on a wait, so a hang fails at its own line instead of riding out the
/// suite's time limit.
public enum Ceiling {
    /// Re-reads `condition` every `interval` until it holds or `limit` passes, and returns
    /// whether it held. Runs on the caller's actor, so a `@MainActor` condition stays isolated.
    public nonisolated(nonsending) static func poll(
        _ limit: Duration,
        every interval: Duration = .milliseconds(20),
        until condition: () async throws -> Bool
    ) async throws -> Bool {
        let deadline = ContinuousClock.now + limit
        while try await !condition() {
            guard ContinuousClock.now < deadline else { return false }
            try await Task.sleep(for: interval)
        }
        return true
    }
}
