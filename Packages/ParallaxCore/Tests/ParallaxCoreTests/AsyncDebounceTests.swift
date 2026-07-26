import Foundation
import ParallaxCoreTestSupport
import Testing
@testable import ParallaxCore

/// Driven by a `ManualSleeper` instead of real sleeps: the test releases each pending delay and
/// then awaits the stream, so "did the burst collapse?" is answered by the emitted values rather
/// than by whether a 200ms sleep out-ran the scheduler.
@Suite("AsyncDebounce")
struct AsyncDebounceTests {
    @Test("a burst collapses to the last value")
    func collapsesRapidCalls() async {
        let sleeper = ManualSleeper()
        let debouncer = AsyncDebouncer<String>(
            delay: .milliseconds(100), sleep: { try await sleeper.sleep($0) }
        )
        var values = debouncer.stream.makeAsyncIterator()

        await debouncer.update("a")
        await debouncer.update("ab")
        await debouncer.update("abc")

        // All three pending delays fire; only the last one's task survived cancellation.
        await sleeper.releasePending(expecting: 3)
        #expect(await values.next() == "abc")

        await debouncer.finish()
        #expect(await values.next() == nil, "the superseded values must never reach the stream")
    }

    @Test("updates separated by a full delay each emit")
    func separatedCallsEmitSeparately() async {
        let sleeper = ManualSleeper()
        let debouncer = AsyncDebouncer<Int>(
            delay: .milliseconds(50), sleep: { try await sleeper.sleep($0) }
        )
        var values = debouncer.stream.makeAsyncIterator()

        await debouncer.update(1)
        await sleeper.releasePending(expecting: 1)
        #expect(await values.next() == 1)

        await debouncer.update(2)
        await sleeper.releasePending(expecting: 1)
        #expect(await values.next() == 2)

        await debouncer.finish()
        #expect(await values.next() == nil)
    }

    @Test("finish() cancels the pending emission instead of leaking it")
    func finishDropsPendingValue() async {
        let sleeper = ManualSleeper()
        let debouncer = AsyncDebouncer<Int>(
            delay: .milliseconds(50), sleep: { try await sleeper.sleep($0) }
        )
        var values = debouncer.stream.makeAsyncIterator()

        await debouncer.update(99)
        await debouncer.finish()
        // The delay resolves only AFTER the debouncer was finished — a settled search term
        // arriving post-teardown must not be delivered.
        await sleeper.releasePending(expecting: 1)

        #expect(await values.next() == nil)
    }

    /// A sleep that fails for a reason OTHER than cancellation must drop the emission too — a
    /// half-typed search term escaping after an unexpected failure would be worse than none.
    @Test("an unexpected sleep failure drops the pending value instead of emitting it")
    func unexpectedSleepFailureDropsPendingValue() async {
        struct SleepFailure: Error {}

        let sleeper = ManualSleeper()
        let debouncer = AsyncDebouncer<Int>(
            delay: .milliseconds(50), sleep: { try await sleeper.sleep($0) }
        )
        var values = debouncer.stream.makeAsyncIterator()

        await debouncer.update(7)
        await sleeper.releasePending(expecting: 1, throwing: SleepFailure())
        await debouncer.finish()

        #expect(await values.next() == nil)
    }
}
