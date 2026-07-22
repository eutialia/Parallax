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
                // observes the loser's cancellation, so the test leaks no 30s task.
                try await Task.sleep(for: .seconds(30))
                return 0
            }
        }
        // The caller must be released at ~the ceiling, not when the hung operation finishes.
        // The bound only needs to discriminate ceiling (0.2s) from hung-op completion (30s);
        // 15s absorbs loaded-CI scheduling latency (6.7s observed) without losing that.
        #expect(ContinuousClock.now - start < .seconds(15))
    }

    @Test("Caller cancellation settles the race immediately")
    func callerCancellationSettlesEarly() async {
        let start = ContinuousClock.now
        let racing = Task {
            try await withHardTimeout(seconds: 30) { () -> Int in
                try await Task.sleep(for: .seconds(30))
                return 0
            }
        }
        try? await Task.sleep(for: .seconds(0.1))
        racing.cancel()
        // Must throw (CancellationError) well before either the operation or the 30s ceiling.
        await #expect(throws: (any Error).self) { try await racing.value }
        #expect(ContinuousClock.now - start < .seconds(15))
    }
}
