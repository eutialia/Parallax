import Testing
import ParallaxCore
@testable import Parallax

/// A `ReachabilityMonitoring` whose stream is driven by the test — no real `NWPathMonitor`. Pushes
/// raw values so it can also exercise the un-deduped path (the live monitor dedupes upstream; the
/// `ConnectivityMonitor` just republishes whatever it receives).
private final class MockReachabilityMonitoring: ReachabilityMonitoring, @unchecked Sendable {
    let pathUpdates: AsyncStream<Bool>
    private let continuation: AsyncStream<Bool>.Continuation

    init() {
        (pathUpdates, continuation) = AsyncStream<Bool>.makeStream()
    }

    func send(_ satisfied: Bool) { continuation.yield(satisfied) }
    func finish() { continuation.finish() }
}

@MainActor
@Suite("ConnectivityMonitor")
struct ConnectivityMonitorTests {
    @Test("defaults to online before the first path update")
    func defaultsOnline() {
        #expect(ConnectivityMonitor(monitor: MockReachabilityMonitoring()).isOnline)
    }

    @Test("republishes each reachability transition into isOnline")
    func republishesTransitions() async {
        let mock = MockReachabilityMonitoring()
        let monitor = ConnectivityMonitor(monitor: mock)
        let task = Task { await monitor.observe() }

        mock.send(false)
        await waitUntil { monitor.isOnline == false }
        #expect(monitor.isOnline == false)

        mock.send(true)
        await waitUntil { monitor.isOnline == true }
        #expect(monitor.isOnline == true)

        task.cancel()
        mock.finish()
    }

    @Test("observe() returns when the stream finishes")
    func observeEndsOnFinish() async {
        let mock = MockReachabilityMonitoring()
        let monitor = ConnectivityMonitor(monitor: mock)
        mock.send(false)
        mock.finish()
        // Completes (doesn't hang) because the finished stream ends the for-await loop.
        await monitor.observe()
        #expect(monitor.isOnline == false)
    }
}
