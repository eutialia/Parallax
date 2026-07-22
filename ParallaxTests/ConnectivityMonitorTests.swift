import Testing
import ParallaxCore
import ParallaxPlayback
@testable import Parallax

/// A `ReachabilityMonitoring` whose stream is driven by the test — no real `NWPathMonitor`. Pushes
/// raw values so it can also exercise the un-deduped path (the live monitor dedupes upstream; the
/// `ConnectivityMonitor` just republishes whatever it receives).
private final class MockReachabilityMonitoring: ReachabilityMonitoring, @unchecked Sendable {
    let pathUpdates: AsyncStream<ReachabilityState>
    private let continuation: AsyncStream<ReachabilityState>.Continuation

    init() {
        (pathUpdates, continuation) = AsyncStream<ReachabilityState>.makeStream()
    }

    func send(_ satisfied: Bool, isConstrained: Bool = false) {
        continuation.yield(ReachabilityState(isSatisfied: satisfied, isConstrained: isConstrained))
    }
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

    @Test("forwards the constrained signal to the profile builder only while satisfied")
    func forwardsConstraintGatedOnSatisfied() async {
        let mock = MockReachabilityMonitoring()
        let monitor = ConnectivityMonitor(monitor: mock)
        let builder = DeviceProfileBuilder(probe: StubCapabilityProbe())
        let task = Task { await monitor.observe(reportingConstraintTo: builder) }

        // Satisfied + constrained clamps the profile bitrate.
        mock.send(true, isConstrained: true)
        #expect(await eventually { await builder.build().maxBitrate == .megabits(8) })

        // A connectivity blip (unsatisfied, constrained bit meaningless) must NOT lift the
        // clamp. The isOnline flip is the barrier proving the loop processed the element.
        mock.send(false, isConstrained: false)
        await waitUntil { monitor.isOnline == false }
        #expect(await builder.build().maxBitrate == .megabits(8))

        // Re-satisfaction with Low Data Mode off un-clamps.
        mock.send(true, isConstrained: false)
        #expect(await eventually { await builder.build().maxBitrate == .megabits(360) })

        task.cancel()
        mock.finish()
    }
}

/// Minimal local `CapabilityProbe` — deliberately NOT the `ParallaxPlaybackTestSupport` fake:
/// linking a test-support product into the app-hosted bundle statically duplicates ParallaxCore
/// (same reason this target keeps its own `FakeKeychain`).
private struct StubCapabilityProbe: CapabilityProbe {
    @MainActor func hdrSupport() -> HDRSupport { .none }
    func audioOutput() -> AudioOutputCapability { .stereo }
}

/// Polls an async predicate (the sync `waitUntil` can't await actor state like the builder's).
private func eventually(_ predicate: () async -> Bool) async -> Bool {
    for _ in 0..<200 {
        if await predicate() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await predicate()
}
