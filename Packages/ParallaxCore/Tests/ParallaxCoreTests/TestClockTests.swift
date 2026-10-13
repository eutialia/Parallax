import ParallaxCoreTestSupport
import Synchronization
import Testing

@Suite("TestClock", .timeLimit(.minutes(1)))
struct TestClockTests {
    @Test("waiting for a sleep by its duration holds until that sleep parks, whatever else is parked")
    func waitsForTheSleepItNames() async throws {
        let clock = TestClock()
        let unrelated = Task { try await clock.sleep(for: .seconds(5)) }
        try await clock.waitForSleep(dueIn: .seconds(5))
        let target = Task { try await clock.sleep(for: .seconds(15)) }

        try await clock.waitForSleep(dueIn: .seconds(15))
        clock.advance(by: .seconds(15))

        try await target.value
        try await unrelated.value
    }

    @Test("one advance fires a periodic sleep once for every deadline it crosses")
    func periodicSleepCatchesUp() async throws {
        let clock = TestClock()
        let ticks = Mutex<[Duration]>([])
        let start = clock.now
        let timer = Task {
            while true {
                try await clock.sleep(for: .seconds(1))
                ticks.withLock { $0.append(start.duration(to: clock.now)) }
            }
        }
        try await clock.waitForSleep(dueIn: .seconds(1))

        clock.advance(by: .seconds(3.5))
        try await clock.waitForSleep(dueIn: .seconds(0.5))

        #expect(ticks.withLock { $0 } == [.seconds(1), .seconds(2), .seconds(3)])
        timer.cancel()
    }

    @Test("sleeping until a deadline already past does not move the sleeper's now backwards")
    func pastDeadlineKeepsNow() async throws {
        let clock = TestClock()
        let start = clock.now
        clock.advance(by: .seconds(10))

        let seen = try await Task {
            try await clock.sleep(until: start.advanced(by: .seconds(2)))
            return start.duration(to: clock.now)
        }.value

        #expect(seen == .seconds(10))
    }

    @Test("pending sleeps show the time left on each, and a cancelled sleep leaves the list")
    func pendingSleepsTrackTimeLeft() async throws {
        let clock = TestClock()
        let short = Task { try await clock.sleep(for: .seconds(2)) }
        let long = Task { try await clock.sleep(for: .seconds(10)) }
        try await clock.waitForSleep(dueIn: .seconds(2))
        try await clock.waitForSleep(dueIn: .seconds(10))

        clock.advance(by: .seconds(1))
        #expect(clock.pendingSleeps == [.seconds(1), .seconds(9)])

        long.cancel()
        #expect(clock.pendingSleeps == [.seconds(1)])
        short.cancel()
    }
}
