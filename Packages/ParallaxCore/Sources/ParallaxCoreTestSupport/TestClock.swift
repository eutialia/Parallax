import ParallaxTestScaling
import Synchronization

/// A `Clock` that only moves when the test calls `advance(by:)`.
///
/// Hand it to a type's clock seam in place of `ContinuousClock`; every `sleep` parks until the test
/// advances past its deadline, so time-shaped behaviour runs on the test's schedule instead of
/// racing the wall clock. A sleep is spawned asynchronously by the code under test, so advance only
/// after `waitForSleep(dueIn:)` confirms the one you mean has parked; advancing first moves `now`
/// under a sleep that has not computed its deadline yet, and that sleep never wakes.
///
/// `now` is task-relative: a task woken by `advance` reads the deadline it fired at until it sleeps
/// again or the next `advance`, so a periodic sleep catches up one tick per crossed deadline. A
/// task's view never moves backwards: sleeping until a deadline already past leaves it where it
/// was. Every other task reads the clock's time.
///
/// `advance` returns before the woken work runs, and nothing can tell when that work is done, so a
/// state read right after it shows the state from before the wake. Prove "not yet" and "never" on
/// `pendingSleeps` instead: a sleep that is not parked, or not due before the claim's instant, can't
/// fire.
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

    /// No sleep due `dueIn` from now parked before the anti-hang ceiling.
    public struct SleepNeverParked: Error, CustomStringConvertible {
        public let dueIn: Duration
        public let parked: [Duration]
        public var description: String {
            "no sleep due in \(dueIn) parked on the test clock; parked: \(parked)"
        }
    }

    private struct Sleeper {
        let deadline: Instant
        let continuation: CheckedContinuation<Instant, any Error>
    }

    private struct ArrivalWaiter {
        let id: Int
        let deadline: Instant
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
        /// The deadline each task woken by the last `advance` fired at. That task reads it as `now`
        /// until it sleeps again, so a periodic sleep re-queues from its own deadline rather than
        /// from wherever the advance stopped, and fires once per deadline the advance crossed. Keyed by
        /// the task's hash: `UnsafeCurrentTask` itself is not `Sendable`.
        var wokenAt: [Int: Instant] = [:]

        mutating func takeSatisfiedWaiters() -> [CheckedContinuation<Void, Never>] {
            let parked = Set(sleepers.values.map(\.deadline))
            let satisfied = arrivalWaiters.filter { parked.contains($0.deadline) }
            arrivalWaiters.removeAll { parked.contains($0.deadline) }
            return satisfied.map(\.continuation)
        }
    }

    private let state = Mutex(State())

    public init() {}

    public var now: Instant {
        let task = withUnsafeCurrentTask { $0?.hashValue }
        return state.withLock { state in task.flatMap { state.wokenAt[$0] } ?? state.now }
    }

    public var minimumResolution: Duration { .zero }

    public func sleep(until deadline: Instant, tolerance: Duration? = nil) async throws {
        let id = state.withLock { state in
            defer { state.nextID += 1 }
            return state.nextID
        }
        let task = withUnsafeCurrentTask { $0?.hashValue }
        let firedAt = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Instant, any Error>) in
                enum Arrival { case cancelled, due(Instant), parked([CheckedContinuation<Void, Never>]) }
                let arrival = state.withLock { state -> Arrival in
                    let seen = task.flatMap { state.wokenAt[$0] } ?? state.now
                    if let task { state.wokenAt[task] = nil }
                    if state.cancelledBeforeParking.remove(id) != nil { return .cancelled }
                    if deadline <= state.now { return .due(max(deadline, seen)) }
                    state.sleepers[id] = Sleeper(deadline: deadline, continuation: continuation)
                    return .parked(state.takeSatisfiedWaiters())
                }
                switch arrival {
                case .cancelled:
                    continuation.resume(throwing: CancellationError())
                case .due(let firedAt):
                    continuation.resume(returning: firedAt)
                case .parked(let waiters):
                    waiters.forEach { $0.resume() }
                }
            }
        } onCancel: {
            let parked = state.withLock { state in
                guard let sleeper = state.sleepers.removeValue(forKey: id) else {
                    state.cancelledBeforeParking.insert(id)
                    return nil as CheckedContinuation<Instant, any Error>?
                }
                return sleeper.continuation
            }
            parked?.resume(throwing: CancellationError())
        }
        if let task { state.withLock { $0.wokenAt[task] = firedAt } }
    }

    /// Moves `now` forward and wakes every sleep whose deadline it reached, earliest first. A woken
    /// task that sleeps again computes its next deadline from the one it fired at, so a periodic
    /// sleep fires once for every deadline the advance crossed.
    public func advance(by duration: Duration) {
        let due = state.withLock { state in
            state.wokenAt.removeAll()
            state.now = state.now.advanced(by: duration)
            let now = state.now
            let due = state.sleepers
                .filter { $0.value.deadline <= now }
                .sorted { $0.value.deadline < $1.value.deadline }
            due.forEach { state.sleepers.removeValue(forKey: $0.key) }
            return due.map(\.value)
        }
        due.forEach { $0.continuation.resume(returning: $0.deadline) }
    }

    /// The time left on every parked sleep, soonest first.
    public var pendingSleeps: [Duration] {
        state.withLock { state in
            state.sleepers.values.map { state.now.duration(to: $0.deadline) }.sorted()
        }
    }

    /// Returns once a sleep due exactly `dueIn` from now is parked, whatever else is parked on the
    /// clock. Throws `SleepNeverParked` past a CI-scaled ceiling, and `CancellationError` when the
    /// suite's `.timeLimit` cancels the wait.
    public func waitForSleep(dueIn: Duration) async throws {
        let deadline = state.withLock { $0.now.advanced(by: dueIn) }
        let parked = try await withThrowingTaskGroup(of: Bool.self) { group in
            group.addTask {
                await self.arrival(of: deadline)
                return true
            }
            group.addTask {
                try await Ceiling.expire(CITimeScale.seconds(5))
                return false
            }
            defer { group.cancelAll() }
            return try await group.next() ?? false
        }
        try Task.checkCancellation()
        guard parked else { throw SleepNeverParked(dueIn: dueIn, parked: pendingSleeps) }
    }

    private func arrival(of deadline: Instant) async {
        let id = state.withLock { state in
            defer { state.nextID += 1 }
            return state.nextID
        }
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let ready = state.withLock { state in
                    if state.cancelledBeforeParking.remove(id) != nil
                        || state.sleepers.values.contains(where: { $0.deadline == deadline }) { return true }
                    state.arrivalWaiters.append(ArrivalWaiter(id: id, deadline: deadline, continuation: continuation))
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
