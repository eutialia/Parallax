import Foundation
import Testing
@testable import ParallaxFileBrowse

/// Pins the pure AIMD policy behind per-host thumbnail admission — seed widths, additive growth
/// paced by the current limit, the hard ceiling, multiplicative shrink with a floor of 1, and
/// recovery after a shrink. No actor, no queue; the gate integration lives in app-hosted tests.
@Suite("SMBAdmissionWindow", .timeLimit(.minutes(3)))
struct SMBAdmissionWindowTests {

    struct SeedCase: Sendable, CustomTestStringConvertible {
        let name: String
        let seed: SMBLinkClass?
        let expectedLimit: Int
        var testDescription: String { name }

        init(_ name: String, seed: SMBLinkClass?, expectedLimit: Int) {
            self.name = name
            self.seed = seed
            self.expectedLimit = expectedLimit
        }
    }

    static let seedCases: [SeedCase] = [
        .init("lan seeds limit 3", seed: .lan, expectedLimit: 3),
        .init("wan seeds limit 1", seed: .wan, expectedLimit: 1),
        .init("nil seeds limit 1", seed: nil, expectedLimit: 1),
    ]

    @Test("seed values per link class set the starting limit", arguments: seedCases)
    func seedLimits(_ testCase: SeedCase) {
        let window = SMBAdmissionWindow(seed: testCase.seed)
        #expect(window.limit == testCase.expectedLimit)
    }

    @Test("a full window of successes earns exactly one more integer slot")
    func growthNeedsFullWindowOfSuccesses() {
        var window = SMBAdmissionWindow(seed: .lan)
        #expect(window.limit == 3)

        // Two successes on a limit-3 window must not raise the integer limit yet.
        window.recordSuccess()
        #expect(window.limit == 3)
        window.recordSuccess()
        #expect(window.limit == 3)

        // The third completes a full window's worth → limit becomes 4.
        window.recordSuccess()
        #expect(window.limit == 4)
    }

    @Test("repeated successes never push the limit past the ceiling of 4")
    func ceilingCapsGrowth() {
        var window = SMBAdmissionWindow(seed: .lan)
        // Far more than enough successes to climb past 4 if the ceiling were missing.
        for _ in 0..<200 {
            window.recordSuccess()
        }
        #expect(window.limit == 4)
    }

    @Test("transport failure halves a wide window; floor stays at 1")
    func halvingAndFloor() {
        var wide = SMBAdmissionWindow(seed: .lan)
        // Grow past seed so the post-halve limit is observable (and not still 3).
        for _ in 0..<3 { wide.recordSuccess() }  // 3 → 4
        #expect(wide.limit == 4)
        wide.recordTransportFailure()
        // window was 4.0 → 2.0; limit floors to 2.
        #expect(wide.limit == 2)

        var floor = SMBAdmissionWindow(seed: .wan)
        #expect(floor.limit == 1)
        floor.recordTransportFailure()
        #expect(floor.limit == 1)
        floor.recordTransportFailure()
        #expect(floor.limit == 1)
    }

    @Test("a window that just failed can grow again on subsequent successes")
    func recoveryAfterShrink() {
        var window = SMBAdmissionWindow(seed: .lan)
        for _ in 0..<3 { window.recordSuccess() }  // 3 → 4
        window.recordTransportFailure()            // 4 → 2
        #expect(window.limit == 2)

        // Two successes on limit-2 earn one slot (2.0 + 0.5 + 0.5 = 3.0).
        window.recordSuccess()
        #expect(window.limit == 2)
        window.recordSuccess()
        #expect(window.limit == 3)
    }
}
