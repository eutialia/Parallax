import Foundation

public actor AsyncDebouncer<Value: Sendable> {
    public nonisolated let stream: AsyncStream<Value>
    private let continuation: AsyncStream<Value>.Continuation
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
                guard !Task.isCancelled else { return }
                continuation.yield(value)
            } catch {
                // Sleep cancelled — drop the update.
            }
        }
    }

    public func finish() {
        currentTask?.cancel()
        continuation.finish()
    }
}
