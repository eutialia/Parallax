import Foundation
import CoreMedia
import Testing
@testable import Parallax

@Suite("ResumePolicy")
struct ResumePolicyTests {
    // 10_000_000 ticks per second.
    @Test("Returns nil under the 5s floor")
    func belowFloor() {
        let t = ResumePolicy.resumeStartTime(positionTicks: 4 * 10_000_000, runtime: .seconds(7200))
        #expect(t == nil)
    }

    @Test("Returns nil above the 95% ceiling")
    func aboveCeiling() {
        // 96% of a 100s runtime → 96s.
        let t = ResumePolicy.resumeStartTime(positionTicks: 96 * 10_000_000, runtime: .seconds(100))
        #expect(t == nil)
    }

    @Test("Returns a CMTime in the resumable window")
    func resumable() {
        // 600s into a 7200s runtime → well inside [5s, 95%].
        let t = ResumePolicy.resumeStartTime(positionTicks: 600 * 10_000_000, runtime: .seconds(7200))
        #expect(t != nil)
        #expect(abs(CMTimeGetSeconds(t!) - 600) < 0.001)
    }

    @Test("Returns nil when runtime is nil (can't compute the ceiling)")
    func nilRuntime() {
        let t = ResumePolicy.resumeStartTime(positionTicks: 600 * 10_000_000, runtime: nil)
        #expect(t == nil)
    }

    @Test("Zero position returns nil")
    func zeroPosition() {
        let t = ResumePolicy.resumeStartTime(positionTicks: 0, runtime: .seconds(7200))
        #expect(t == nil)
    }
}
