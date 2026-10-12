import Synchronization

/// A `Clock` that only moves when the test calls `advance(by:)`.
///
/// Hand it to a type's clock seam in place of `ContinuousClock`; every `sleep` parks until the test
/// advances past its deadline, so time-shaped behaviour runs on the test's schedule instead of
/// racing the wall clock. A sleep is spawned asynchronously by the code under test, so advance only
/// after `waitForSleepers(_:)` confirms it has parked; advancing first moves `now` under a sleep
/// that has not computed its deadline yet, and that sleep never wakes.
public final class TestClock: Clock, Sendable {
    public struct Instant: InstantProtocol {
        fileprivate let offset: Duration

        public func advanced(by duration: Duration) -> Instant {
            Instant(offset: offset + duration)
        }

        public func duration(to other: Instant) -> Duration {
            other.offset - offset
        }

        public static func < (lhs: Instant, rhs: Instant) -> Bool {
            lhs.offset < rhs.offset
        }
    }

    private struct Sleeper {
        let deadline: Instant
        let continuation: CheckedContinuation<Void, any Error>
    }

    private struct ArrivalWaiter {
        let id: Int
        let count: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    private struct State {
        var now = Instant(offset: .zero)
        var nextID = 0
        var sleepers: [Int: Sleeper] = [:]
        /// Sleeps and arrival waits cancelled before they parked: the cancellation handler can run
        /// first, and the call must then return on arrival instead of parking forever.
        var cancelledBeforeParking: Set<Int> = []
        var arrivalWaiters: [ArrivalWaiter] = []

        mutating func takeSatisfiedWaiters() -> [CheckedContinuation<Void, Never>] {
            let satisfied = arrivalWaiters.filter { $0.count <= sleepers.count }
            arrivalWaiters.removeAll { $0.count <= sleepers.count }
            return satisfied.map(\.continuation)
        }
    }

    private let state = Mutex(State())

    public init() {}

    public var now: Instant { state.withLock { $0.now } }

    public var minimumResolution: Duration { .zero }

    public func sleep(until deadline: Instant, tolerance: Duration? = nil) async throws {
        let id = state.withLock { state in
            defer { state.nextID += 1 }
            return state.nextID
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                enum Arrival { case cancelled, due, parked([CheckedContinuation<Void, Never>]) }
                let arrival = state.withLock { state -> Arrival in
                    if state.cancelledBeforeParking.remove(id) != nil { return .cancelled }
                    if deadline <= state.now { return .due }
                    state.sleepers[id] = Sleeper(deadline: deadline, continuation: continuation)
                    return .parked(state.takeSatisfiedWaiters())
                }
                switch arrival {
                case .cancelled:
                    continuation.resume(throwing: CancellationError())
                case .due:
                    continuation.resume()
                case .parked(let waiters):
                    waiters.forEach { $0.resume() }
                }
            }
        } onCancel: {
            let parked = state.withLock { state in
                guard let sleeper = state.sleepers.removeValue(forKey: id) else {
                    state.cancelledBeforeParking.insert(id)
                    return nil as CheckedContinuation<Void, any Error>?
                }
                return sleeper.continuation
            }
            parked?.resume(throwing: CancellationError())
        }
    }

    /// Moves `now` forward and wakes every sleep whose deadline it reached, earliest first.
    public func advance(by duration: Duration) {
        let due = state.withLock { state in
            state.now = state.now.advanced(by: duration)
            let now = state.now
            let due = state.sleepers
                .filter { $0.value.deadline <= now }
                .sorted { $0.value.deadline < $1.value.deadline }
            due.forEach { state.sleepers.removeValue(forKey: $0.key) }
            return due.map(\.value.continuation)
        }
        due.forEach { $0.resume() }
    }

    /// Returns once at least `count` sleeps are parked on this clock, or once the waiting task is
    /// cancelled: a suite's `.timeLimit` cancels it, so a scenario whose sleep never parks fails
    /// instead of hanging the run.
    public func waitForSleepers(_ count: Int = 1) async {
        let id = state.withLock { state in
            defer { state.nextID += 1 }
            return state.nextID
        }
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let ready = state.withLock { state in
                    if state.cancelledBeforeParking.remove(id) != nil || state.sleepers.count >= count { return true }
                    state.arrivalWaiters.append(ArrivalWaiter(id: id, count: count, continuation: continuation))
                    return false
                }
                if ready { continuation.resume() }
            }
        } onCancel: {
            let parked = state.withLock { state -> CheckedContinuation<Void, Never>? in
                guard let index = state.arrivalWaiters.firstIndex(where: { $0.id == id }) else {
                    state.cancelledBeforeParking.insert(id)
                    return nil
                }
                return state.arrivalWaiters.remove(at: index).continuation
            }
            parked?.resume()
        }
    }
}
