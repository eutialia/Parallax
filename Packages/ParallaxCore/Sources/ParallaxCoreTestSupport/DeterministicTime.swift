import Foundation

/// A test-driven replacement for `Task.sleep(for:)`.
///
/// Every `sleep(_:)` call parks until the test explicitly releases it, so suites that exercise
/// time-shaped behaviour (`AsyncDebouncer`) drive the schedule themselves instead of racing the
/// wall clock behind margin-padded real sleeps. Pass it into the type under test's `sleep:` seam:
///
/// ```swift
/// let sleeper = ManualSleeper()
/// let debouncer = AsyncDebouncer<Int>(delay: .milliseconds(100), sleep: { await sleeper.sleep($0) })
/// ```
public actor ManualSleeper {
    private var parked: [CheckedContinuation<Void, Error>] = []
    private var arrivalWaiter: (count: Int, continuation: CheckedContinuation<Void, Never>)?

    public init() {}

    /// Drop-in for `Task.sleep(for:)`: parks until `releasePending(expecting:)` wakes it.
    /// The requested duration is ignored on purpose — ordering, not wall time, is what the
    /// suites under test care about.
    public func sleep(_ duration: Duration) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            parked.append(continuation)
            notifyArrivalWaiter()
        }
    }

    /// Waits until exactly `count` sleeps have parked, then resumes all of them — throwing
    /// `failure` into each when given, which models a sleep failing for a reason other than
    /// cancellation.
    ///
    /// Waiting for the arrivals (rather than resuming whatever happens to be parked) is what
    /// makes the caller deterministic: a debounced burst spawns its sleeps asynchronously, so
    /// "release now" would otherwise race the tasks it means to release.
    public func releasePending(expecting count: Int, throwing failure: (any Error)? = nil) async {
        await waitForParked(count)
        let resuming = parked
        parked.removeAll()
        for continuation in resuming {
            if let failure {
                continuation.resume(throwing: failure)
            } else {
                continuation.resume()
            }
        }
    }

    private func waitForParked(_ count: Int) async {
        guard parked.count < count else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            arrivalWaiter = (count, continuation)
        }
    }

    private func notifyArrivalWaiter() {
        guard let waiter = arrivalWaiter, parked.count >= waiter.count else { return }
        arrivalWaiter = nil
        waiter.continuation.resume()
    }
}
