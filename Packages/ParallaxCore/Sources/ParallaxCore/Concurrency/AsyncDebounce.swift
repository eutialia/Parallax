import Foundation

public actor AsyncDebouncer<Value: Sendable> {
    public nonisolated let stream: AsyncStream<Value>
    private nonisolated let continuation: AsyncStream<Value>.Continuation
    private let delay: Duration
    private var currentTask: Task<Void, Never>?

    public init(delay: Duration) {
        self.delay = delay
        (self.stream, self.continuation) = AsyncStream<Value>.makeStream()
    }

    public func update(_ value: Value) {
        currentTask?.cancel()
        let continuation = self.continuation
        let delay = self.delay
        currentTask = Task {
            do {
                try await Task.sleep(for: delay)
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
