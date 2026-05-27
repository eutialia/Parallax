import Foundation

public actor AsyncThrottler<Value: Sendable> {
    public nonisolated let stream: AsyncStream<Value>
    private nonisolated let continuation: AsyncStream<Value>.Continuation
    private let interval: Duration
    private var lastEmission: ContinuousClock.Instant?

    public init(interval: Duration) {
        self.interval = interval
        (self.stream, self.continuation) = AsyncStream<Value>.makeStream()
    }

    public func update(_ value: Value) {
        let now = ContinuousClock.now
        if let last = lastEmission, now - last < interval {
            return
        }
        lastEmission = now
        continuation.yield(value)
    }

    public func finish() {
        continuation.finish()
    }

    deinit {
        continuation.finish()
    }
}
