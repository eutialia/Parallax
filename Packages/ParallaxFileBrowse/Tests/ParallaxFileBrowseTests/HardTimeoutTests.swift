import Foundation
import Testing
@testable import ParallaxFileBrowse

/// The ceiling is driven through the injected `sleep` seam instead of a real clock: the two race
/// tests used to bound a 120s hung operation with 60s of slop, and flaked doing it.
///
/// Time-limited: every test here parks on a gate that only the test itself opens, so a race that
/// stops settling should fail red rather than hang the whole run.
@Suite("Hard timeout race", .timeLimit(.minutes(3)))
struct HardTimeoutTests {

    private struct Boom: Error {}

    @Test("Fast operation wins and returns its value")
    func fastOperationReturns() async throws {
        let value = try await withHardTimeout(seconds: 30) { 42 }
        #expect(value == 42)
    }

    @Test("Operation errors propagate, not masked as timeouts")
    func operationErrorPropagates() async {
        await #expect(throws: Boom.self) {
            try await withHardTimeout(seconds: 30) { () -> Int in throw Boom() }
        }
    }

    /// The point of the unstructured race: the caller is released the instant the ceiling fires,
    /// even though the operation — standing in for AMSMB2 wedged in a C poll loop that cannot
    /// observe cancellation — never finishes.
    @Test("A hung operation is abandoned the moment the ceiling fires")
    func hungOperationTimesOut() async {
        let ceiling = AsyncGate(open: false)
        let hungOperation = AsyncGate(open: false)

        let racing = Task {
            try await withHardTimeout(
                seconds: 30,
                sleep: { _ in await ceiling.pass() },
                operation: { () -> Int in
                    await hungOperation.pass()
                    return 0
                }
            )
        }

        await hungOperation.awaitArrivals()   // the race is genuinely running
        await ceiling.open()                  // …and now the ceiling expires

        await #expect(throws: HardTimeoutError.self) { _ = try await racing.value }

        await hungOperation.open()            // release the abandoned operation
    }

    @Test("Caller cancellation settles the race immediately")
    func callerCancellationSettlesEarly() async {
        let ceiling = AsyncGate(open: false)
        let hungOperation = AsyncGate(open: false)

        let racing = Task {
            try await withHardTimeout(
                seconds: 30,
                sleep: { _ in await ceiling.pass() },
                operation: { () -> Int in
                    await hungOperation.pass()
                    return 0
                }
            )
        }

        await hungOperation.awaitArrivals()
        racing.cancel()

        // Neither the operation nor the ceiling has settled — only the caller's cancellation has.
        await #expect(throws: CancellationError.self) { _ = try await racing.value }

        await hungOperation.open()
        await ceiling.open()
    }

    // MARK: - Abandonment receipts

    /// What the SMB layer decides a connection's fate on: whether the call it just gave up on is
    /// still running, and when that call finally returns. Both losing paths report identically —
    /// the abandonment is visible the instant the caller is resumed, never later.
    @Test("An abandoned operation is reported before the caller resumes, and again when it returns",
          arguments: [Loser.ceiling, .cancellation])
    func abandonedOperationIsReportedThenSettled(_ loser: Loser) async {
        let ceiling = AsyncGate(open: false)
        let hungOperation = AsyncGate(open: false)
        let settlement = SMBOperationSettlement()
        let settled = AsyncGate(open: false)
        settlement.whenSettled { Task { await settled.open() } }

        let racing = Task {
            try await withHardTimeout(
                seconds: 30,
                sleep: { _ in await ceiling.pass() },
                settlement: settlement,
                operation: { () -> Int in
                    await hungOperation.pass()
                    return 0
                }
            )
        }
        await hungOperation.awaitArrivals()

        switch loser {
        case .ceiling:
            await ceiling.open()
            await #expect(throws: HardTimeoutError.self) { _ = try await racing.value }
        case .cancellation:
            racing.cancel()
            await #expect(throws: CancellationError.self) { _ = try await racing.value }
        }

        #expect(settlement.isAbandoned, "the caller must be able to read this in its own catch block")

        // The abandoned call keeps running until it doesn't — only then is anything holding it free.
        await hungOperation.open()
        await settled.pass()
    }

    enum Loser: Sendable { case ceiling, cancellation }

    @Test("An operation that WINS its race is never reported as abandoned")
    func winningOperationIsNeverAbandoned() async throws {
        let settlement = SMBOperationSettlement()
        let value = try await withHardTimeout(seconds: 30, settlement: settlement) { 42 }

        #expect(value == 42)
        #expect(settlement.isAbandoned == false, "nothing was left running — this borrow is reusable")
    }
}
