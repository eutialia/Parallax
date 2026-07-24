import Foundation
import Testing
@testable import ParallaxFileBrowse

@Suite("Hard timeout race")
struct HardTimeoutTests {
    @Test("Fast operation wins and returns its value")
    func fastOperationReturns() async throws {
        let value = try await withHardTimeout(seconds: 5) { 42 }
        #expect(value == 42)
    }

    @Test("Operation errors propagate, not masked as timeouts")
    func operationErrorPropagates() async {
        struct Boom: Error {}
        await #expect(throws: Boom.self) {
            try await withHardTimeout(seconds: 5) { () -> Int in throw Boom() }
        }
    }

    @Test("Hung operation is abandoned at the ceiling")
    func hungOperationTimesOut() async {
        let start = ContinuousClock.now
        await #expect(throws: HardTimeoutError.self) {
            try await withHardTimeout(seconds: 0.2) { () -> Int in
                // Stands in for AMSMB2 blocking in an unbounded phase. Unlike the C call it
                // observes the loser's cancellation, so the test leaks no 120s task.
                try await Task.sleep(for: .seconds(120))
                return 0
            }
        }
        // The caller must be released at ~the ceiling, not when the hung operation finishes.
        // The bound only needs to discriminate ceiling (0.2s) from hung-op completion (120s);
        // the hung op sleeps 120s (not 30s) precisely so a 60s bound can absorb whole-process
        // CI scheduler stalls (22s observed — a 15s bound against a 30s op flaked) while
        // keeping 2× discrimination. Normal runs still finish in ~0.2s.
        #expect(ContinuousClock.now - start < .seconds(60))
    }

    @Test("Caller cancellation settles the race immediately")
    func callerCancellationSettlesEarly() async {
        let start = ContinuousClock.now
        let racing = Task {
            try await withHardTimeout(seconds: 120) { () -> Int in
                try await Task.sleep(for: .seconds(120))
                return 0
            }
        }
        try? await Task.sleep(for: .seconds(0.1))
        racing.cancel()
        // Must throw (CancellationError) well before either the operation or the 120s ceiling.
        // Same stall-tolerant geometry as above: settle ~0.1s, bound 60s, hung side 120s.
        await #expect(throws: (any Error).self) { try await racing.value }
        #expect(ContinuousClock.now - start < .seconds(60))
    }
}
