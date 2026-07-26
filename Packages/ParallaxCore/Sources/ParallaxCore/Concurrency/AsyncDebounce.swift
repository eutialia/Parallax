import Foundation

/// Coalesces a burst of `update(_:)` calls into a single emission on `stream`, delivered
/// `delay` after the last update. Each new value cancels the pending one — for-await over
/// `stream` to receive only the settled value (e.g. a search field that fires once typing stops).
public actor AsyncDebouncer<Value: Sendable> {
    /// The debounced output; for-await over it to receive settled values.
    public nonisolated let stream: AsyncStream<Value>
    private nonisolated let continuation: AsyncStream<Value>.Continuation
    private let delay: Duration
    private let sleep: @Sendable (Duration) async throws -> Void
    private var currentTask: Task<Void, Never>?

    /// - Parameter sleep: how the pending emission waits out the delay. Defaults to
    ///   `Task.sleep(for:)`; tests inject a manually released sleeper so debounce ordering is
    ///   driven by the test rather than by the scheduler.
    public init(
        delay: Duration,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.delay = delay
        self.sleep = sleep
        (self.stream, self.continuation) = AsyncStream<Value>.makeStream()
    }

    public func update(_ value: Value) {
        currentTask?.cancel()
        let continuation = self.continuation
        let delay = self.delay
        let sleep = self.sleep
        currentTask = Task {
            do {
                try await sleep(delay)
            } catch is CancellationError {
                return
            } catch {
                Log.persistence.error("AsyncDebouncer: unexpected sleep error \(error.localizedDescription)")
                return
            }
            guard !Task.isCancelled else { return }
            continuation.yield(value)
        }
    }

    public func finish() {
        currentTask?.cancel()
        continuation.finish()
    }

    deinit {
        // Stream consumers iterating `.stream` exit cleanly on owner release.
        // The unstructured Task captures `continuation` by value, not `self`,
        // so its pending yield (if any) becomes a no-op after `finish()`.
        continuation.finish()
    }
}
