import Foundation
import os

/// Thrown by `withHardTimeout` when the ceiling expires before the operation finishes.
///
/// Public because `withHardTimeout` is: an app-side caller (the thumbnail sidecar tier) has to be
/// able to tell "the ceiling fired" — link evidence — from a content-level failure, and it cannot
/// do that without naming the error the public API throws at it.
public struct HardTimeoutError: Error, Sendable {
    public init() {}
}

/// Races `operation` against a wall-clock ceiling; whichever finishes first wins the result, and
/// caller cancellation settles the race immediately with `CancellationError`.
///
/// Exists because AMSMB2's C poll loop cannot observe Swift cancellation and its `timeout`
/// property bounds SMB PDU responses only — NOT every phase of a connect (name resolution in
/// particular can block far past it on device). A structured `withThrowingTaskGroup` race
/// cannot express this: the group awaits all children before returning, so an uncancellable
/// hung child would block the "timed out" throw for exactly as long as the hang. Hence the
/// unstructured first-wins race. On timeout or cancellation the losing operation keeps running
/// detached until the C call returns, and its result is dropped (the same drop SMB callers
/// already accept when they abandon an in-flight connect). Keeping the loser alive is also what
/// holds the connection alive, so nothing frees it under a pending call; the losing TIMER, by
/// contrast, is always cancelled so a fast success doesn't leave a sleeper holding the race
/// state for the full ceiling. An optional `settlement` reports that abandonment back to the
/// caller — both that it happened and, later, that the abandoned call finally returned.
///
/// - Parameters:
///   - seconds: the ceiling handed to `sleep`.
///   - sleep: how the ceiling is waited out. Defaults to `Task.sleep`; injectable so a test can
///     fire the ceiling on demand instead of racing a real clock. Behaviour is unchanged for
///     every production caller, which all take the default.
///   - settlement: optional receipt for the ABANDONED operation. When the race is lost with the
///     operation still running, this is marked abandoned *before* the caller is resumed (so the
///     caller's `catch` can trust it), and marked settled when that detached operation finally
///     returns. Callers that must not release a connection under a pending native call read it;
///     everyone else passes nil and pays nothing.
///   - operation: the work being raced.
public func withHardTimeout<T: Sendable>(
    seconds: TimeInterval,
    sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) },
    settlement: SMBOperationSettlement? = nil,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    // Everything the three settlers (completion, timeout, caller cancellation) touch lives
    // behind one lock, because any of them can fire before the continuation is installed —
    // a result arriving early is parked in `pendingResult` and delivered by the installer.
    let race = OSAllocatedUnfairLock(initialState: HardTimeoutRace<T>())

    /// Settle exactly once: first claimant resumes the continuation and cancels both racers.
    ///
    /// Returns whether `result` became (or is parked to become) the race's outcome — which is how
    /// the operation learns it LOST and is now running detached. `operationFinished` is set by the
    /// operation's own call in the same locked step, so whoever claims can tell from one flag
    /// whether the operation is still running, without caring who the claimant was.
    ///
    /// A PARKED outcome always wins over the claimant's own: whoever got there before the
    /// continuation existed already decided the race, and resuming with a later result instead would
    /// hand the caller an outcome that contradicts what the settlement recorded — the narrow window
    /// where a healthy connection ends up neither settled nor abandoned and parks for good.
    @Sendable @discardableResult
    func settle(_ result: Result<T, Error>, operationFinished: Bool = false) -> Bool {
        let outcome: (claim: (CheckedContinuation<T, Error>, Result<T, Error>,
                              Task<Void, Never>?, Task<Void, Never>?)?,
                      owned: Bool, abandonsOperation: Bool) =
            race.withLock { state in
                if operationFinished { state.operationFinished = true }
                guard !state.claimed else { return (nil, false, false) }
                guard let continuation = state.continuation else {
                    // Raced ahead of installation — park the outcome for the installer.
                    guard state.pendingResult == nil else { return (nil, false, false) }
                    state.pendingResult = result
                    return (nil, true, false)
                }
                state.claimed = true
                let settled = state.pendingResult ?? result
                return (
                    (continuation, settled, state.work, state.timer),
                    state.pendingResult == nil,
                    !state.operationFinished
                )
            }
        // Before the resume, never after: the caller's `catch` decides a connection's fate off this.
        if outcome.abandonsOperation { settlement?.markAbandoned() }
        guard let (continuation, settled, work, timer) = outcome.claim else { return outcome.owned }
        work?.cancel()
        timer?.cancel()
        continuation.resume(with: settled)
        return outcome.owned
    }

    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
            let work = Task {
                let result: Result<T, Error>
                do { result = .success(try await operation()) }
                catch { result = .failure(error) }
                // Lost the race ⇒ this call ran on detached past the caller's return, and has only
                // now let go of whatever it held. That is the signal a condemned connection waits on.
                if !settle(result, operationFinished: true) { settlement?.markSettled() }
            }
            let timer = Task {
                try? await sleep(seconds)
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
    /// Set the moment the raced operation returns, so a claimant can tell "the operation is still
    /// running" from "it already finished" — the difference between an abandoned call and none.
    var operationFinished = false
    var pendingResult: Result<T, Error>? = nil
    var work: Task<Void, Never>? = nil
    var timer: Task<Void, Never>? = nil
    var continuation: CheckedContinuation<T, Error>? = nil
}

/// A receipt for ONE native SMB call that may outlive the Swift call that issued it.
///
/// libsmb2's calls cannot be cancelled: when a hard timeout fires, a caller is cancelled, or a drain
/// deadline expires, the call keeps running on a dispatch queue and keeps touching its connection.
/// Whoever gave up on it has no other way to learn when that finally stops — and, per the law in
/// `SMBConnectionGraveyard`, must not disconnect or release the connection until it does. This is
/// that signal, in two parts:
///  - `isAbandoned` — the giving-up side left a call running (read at the decision point);
///  - `whenSettled` — that call has now returned, so the connection holds nothing pending.
///
/// Both are one-shot and order-independent: a call that settles before anyone asks still runs a
/// later `whenSettled` body immediately, so the "it settled while we were deciding" race is a
/// non-event. A settlement whose call NEVER returns simply never signals — see the graveyard for
/// what that costs.
///
/// The TYPE is public only because it names a parameter of the public `withHardTimeout`; every
/// member is package-internal, because minting or reading a receipt is a connection-lifecycle
/// concern and this package owns all of those.
public final class SMBOperationSettlement: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: State())

    private struct State {
        var abandoned = false
        var settled = false
        var onSettle: (@Sendable () -> Void)?
    }

    init() {}

    /// Whether a still-running native call was left behind. Meaningful only after the operation it
    /// belongs to has returned control to its caller.
    var isAbandoned: Bool { state.withLock { $0.abandoned } }

    /// Records that the caller gave up while the call was still running.
    func markAbandoned() {
        state.withLock { $0.abandoned = true }
    }

    /// Records that the call returned, releasing anyone waiting on it. Idempotent.
    func markSettled() {
        let body: (@Sendable () -> Void)? = state.withLock { state in
            guard !state.settled else { return nil }
            state.settled = true
            defer { state.onSettle = nil }
            return state.onSettle
        }
        body?()
    }

    /// Runs `body` once the call has returned — immediately if it already has. Waiters chain rather
    /// than replace, so registering twice can never silently drop the first one's connection.
    func whenSettled(_ body: @escaping @Sendable () -> Void) {
        let runNow: Bool = state.withLock { state in
            guard !state.settled else { return true }
            if let queued = state.onSettle {
                state.onSettle = { queued(); body() }
            } else {
                state.onSettle = body
            }
            return false
        }
        if runNow { body() }
    }
}
