import Foundation

/// Rate-limits `update(_:)` to at most one emission per `interval` on `stream`: the first
/// value in a window passes immediately and later ones are dropped until the window elapses
/// (leading-edge throttle). For-await over `stream` to receive the throttled values.
public actor AsyncThrottler<Value: Sendable> {
    /// The throttled output; for-await over it to receive rate-limited values.
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
