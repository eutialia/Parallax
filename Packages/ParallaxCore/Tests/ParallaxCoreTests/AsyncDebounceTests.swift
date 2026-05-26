import Testing
import Foundation
@testable import ParallaxCore

@Suite("AsyncDebounce")
struct AsyncDebounceTests {
    @Test("collapses rapid calls into the last value")
    @MainActor
    func collapsesRapidCalls() async {
        let debouncer = AsyncDebouncer<String>(delay: .milliseconds(100))
        var captured: [String] = []
        let collector = Task {
            for await value in debouncer.stream {
                captured.append(value)
            }
        }

        await debouncer.update("a")
        await debouncer.update("ab")
        await debouncer.update("abc")
        try? await Task.sleep(for: .milliseconds(200))

        await debouncer.finish()
        await collector.value
        #expect(captured == ["abc"])
    }

    @Test("emits multiple values when separated by more than the delay")
    @MainActor
    func separatedCallsEmitSeparately() async {
        let debouncer = AsyncDebouncer<Int>(delay: .milliseconds(50))
        var captured: [Int] = []
        let collector = Task {
            for await value in debouncer.stream {
                captured.append(value)
            }
        }

        await debouncer.update(1)
        try? await Task.sleep(for: .milliseconds(150))
        await debouncer.update(2)
        try? await Task.sleep(for: .milliseconds(150))

        await debouncer.finish()
        await collector.value
        #expect(captured == [1, 2])
    }
}
