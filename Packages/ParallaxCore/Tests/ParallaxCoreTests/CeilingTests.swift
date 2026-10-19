import Synchronization
import Testing
@testable import ParallaxTestScaling

@Suite("Ceiling")
struct CeilingTests {

    /// Laps on a fake wall clock: each one advances it by `lap` and then checks the ceiling.
    private final class Laps: Sendable {
        private let instant = Mutex(ContinuousClock.now)
        func now() -> ContinuousClock.Instant { instant.withLock { $0 } }
        func run(_ lap: Duration, on ceiling: inout Ceiling) -> Bool {
            instant.withLock { $0 += lap }
            return ceiling.remains()
        }
    }

    @Test("a freeze longer than the limit costs one lap")
    func freezeCostsOneLap() {
        let laps = Laps()
        var ceiling = Ceiling(.seconds(5), now: laps.now)

        #expect(laps.run(.seconds(15), on: &ceiling))
    }

    @Test("the ceiling runs out after this many laps", arguments: [
        (limit: Duration.milliseconds(100), lap: Duration.milliseconds(20), runsOutAfter: 5),
        (limit: .seconds(1), lap: .seconds(1), runsOutAfter: 4),
    ])
    func runsOut(limit: Duration, lap: Duration, runsOutAfter expected: Int) {
        let laps = Laps()
        var ceiling = Ceiling(limit, now: laps.now)

        let lapsRun = (1...100).first { _ in !laps.run(lap, on: &ceiling) }

        #expect(lapsRun == expected)
    }
}
