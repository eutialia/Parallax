import Foundation
import os

/// Thrown by `withHardTimeout` when the ceiling expires before the operation finishes.
struct HardTimeoutError: Error {}

/// Races `operation` against a wall-clock ceiling; whichever finishes first wins the result, and
/// caller cancellation settles the race immediately with `CancellationError`.
///
/// Exists because AMSMB2's C poll loop cannot observe Swift cancellation and its `timeout`
/// property bounds SMB PDU responses only — NOT every phase of a connect (name resolution in
/// particular can block far past it on device). A structured `withThrowingTaskGroup` race
/// cannot express this: the group awaits all children before returning, so an uncancellable
/// hung child would block the "timed out" throw for exactly as long as the hang. Hence the
/// unstructured first-wins race. On timeout or cancellation the losing operation keeps running
/// detached until the C call returns, and its result is dropped (the same drop `AMSMB2Lister`
/// callers already accept when they abandon an in-flight connect); the losing TIMER, by
/// contrast, is always cancelled so a fast success doesn't leave a sleeper holding the race
/// state for the full ceiling.
public func withHardTimeout<T: Sendable>(
    seconds: TimeInterval,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    // Everything the three settlers (completion, timeout, caller cancellation) touch lives
    // behind one lock, because any of them can fire before the continuation is installed —
    // a result arriving early is parked in `pendingResult` and delivered by the installer.
    let race = OSAllocatedUnfairLock(initialState: HardTimeoutRace<T>())

    // Settle exactly once: first claimant resumes the continuation and cancels both racers.
    @Sendable func settle(_ result: Result<T, Error>) {
        let claimed: (CheckedContinuation<T, Error>, Task<Void, Never>?, Task<Void, Never>?)? =
            race.withLock { state in
                guard !state.claimed else { return nil }
                guard let continuation = state.continuation else {
                    // Raced ahead of installation — park the outcome for the installer.
                    if state.pendingResult == nil { state.pendingResult = result }
                    return nil
                }
                state.claimed = true
                return (continuation, state.work, state.timer)
            }
        guard let (continuation, work, timer) = claimed else { return }
        work?.cancel()
        timer?.cancel()
        continuation.resume(with: result)
    }

    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
            let work = Task {
                do { settle(.success(try await operation())) }
                catch { settle(.failure(error)) }
            }
            let timer = Task {
                try? await Task.sleep(for: .seconds(seconds))
                guard !Task.isCancelled else { return }
                settle(.failure(HardTimeoutError()))
            }
            let parked: Result<T, Error>? = race.withLock { state in
                state.continuation = continuation
                state.work = work
                state.timer = timer
                if state.callerCancelled { return state.pendingResult ?? .failure(CancellationError()) }
                return state.pendingResult
            }
            if let parked { settle(parked) }
        }
    } onCancel: {
        race.withLock { state in state.callerCancelled = true }
        // No-op if the continuation isn't installed yet: the flag above makes the installer
        // settle with CancellationError itself.
        settle(.failure(CancellationError()))
    }
}

/// Mutable race state for one `withHardTimeout` call. All access goes through the lock.
private struct HardTimeoutRace<T: Sendable>: Sendable {
    var claimed = false
    var callerCancelled = false
    var pendingResult: Result<T, Error>? = nil
    var work: Task<Void, Never>? = nil
    var timer: Task<Void, Never>? = nil
    var continuation: CheckedContinuation<T, Error>? = nil
}
