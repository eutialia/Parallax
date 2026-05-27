import Testing
import Foundation
@testable import ParallaxCore

@Suite("AsyncThrottle")
@MainActor
struct AsyncThrottleTests {
    @Test("emits the first value immediately")
    func emitsFirstImmediately() async {
        let throttler = AsyncThrottler<Int>(interval: .milliseconds(100))
        var captured: [Int] = []
        let collector = Task {
            for await value in throttler.stream {
                captured.append(value)
            }
        }

        await throttler.update(1)
        try? await Task.sleep(for: .milliseconds(20))
        await throttler.finish()
        await collector.value
        #expect(captured == [1])
    }

    @Test("drops values that arrive within the throttle interval")
    func dropsWithinInterval() async {
        let throttler = AsyncThrottler<Int>(interval: .milliseconds(100))
        var captured: [Int] = []
        let collector = Task {
            for await value in throttler.stream {
                captured.append(value)
            }
        }

        await throttler.update(1)
        await throttler.update(2) // within interval, should drop
        try? await Task.sleep(for: .milliseconds(150))
        await throttler.update(3)
        try? await Task.sleep(for: .milliseconds(20))
        await throttler.finish()
        await collector.value
        #expect(captured == [1, 3])
    }
}
