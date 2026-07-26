import Foundation
import Testing
@testable import ParallaxFileBrowse

/// The ceiling is driven through the injected `sleep` seam instead of a real clock: the two race
/// tests used to bound a 120s hung operation with 60s of slop, and flaked doing it.
@Suite("Hard timeout race")
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
}
