import Foundation
import CoreMedia
import Testing
@testable import Parallax

/// One resume decision: a saved position + the item's runtime → the seconds playback
/// should resume at, or nil for "start over" / "already finished". Positions and the
/// window edges are expressed through `ResumePolicy`'s own constants, so a policy
/// change moves the table with it instead of silently invalidating the literals.
private struct ResumeCase: Sendable, CustomTestStringConvertible {
    let name: String
    let seconds: Double
    let runtime: Duration?
    let expected: Double?

    var testDescription: String { name }
    var positionTicks: Int64 { Int64(seconds * ResumePolicy.ticksPerSecond) }
}

private let floorSeconds = ResumePolicy.floorSeconds          // 5s
private let ceiling = ResumePolicy.ceilingFraction            // 0.95

private let resumeCases: [ResumeCase] = [
    .init(name: "zero position → start over", seconds: 0, runtime: .seconds(7200), expected: nil),
    .init(name: "just under the floor → start over",
          seconds: floorSeconds - 1, runtime: .seconds(7200), expected: nil),
    .init(name: "exactly on the floor → resumes (the bound is inclusive)",
          seconds: floorSeconds, runtime: .seconds(7200), expected: floorSeconds),
    .init(name: "mid-item → resumes", seconds: 600, runtime: .seconds(7200), expected: 600),
    .init(name: "exactly on the ceiling → resumes (the bound is inclusive)",
          seconds: ceiling * 100, runtime: .seconds(100), expected: ceiling * 100),
    .init(name: "past the ceiling → treated as finished",
          seconds: ceiling * 100 + 1, runtime: .seconds(100), expected: nil),
    .init(name: "nil runtime → no ceiling to check, so no resume",
          seconds: 600, runtime: nil, expected: nil),
    .init(name: "zero runtime → no timeline to resume into",
          seconds: 600, runtime: .seconds(0), expected: nil),
]

@Suite("ResumePolicy")
struct ResumePolicyTests {
    @Test("resume window: [floor, ceiling × runtime], nil outside it", arguments: resumeCases)
    fileprivate func resumeStartTime(_ c: ResumeCase) throws {
        let t = ResumePolicy.resumeStartTime(positionTicks: c.positionTicks, runtime: c.runtime)
        guard let expected = c.expected else {
            #expect(t == nil)
            return
        }
        let seconds = CMTimeGetSeconds(try #require(t))
        #expect(abs(seconds - expected) < 0.001)
    }
}
