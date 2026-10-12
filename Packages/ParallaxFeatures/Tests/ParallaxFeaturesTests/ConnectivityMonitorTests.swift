import Testing
import ParallaxCore
import ParallaxFeatures
import ParallaxPlayback
import ParallaxPlaybackTestSupport

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
    func republishesTransitions() async throws {
        let mock = MockReachabilityMonitoring()
        let monitor = ConnectivityMonitor(monitor: mock)
        let task = Task { await monitor.observe() }

        mock.send(false)
        try await pollUntil { monitor.isOnline == false }
        #expect(monitor.isOnline == false)

        mock.send(true)
        try await pollUntil { monitor.isOnline == true }
        #expect(monitor.isOnline == true)

        task.cancel()
        mock.finish()
    }

    @Test("counts each offline-to-online edge, and nothing else")
    func countsReconnects() async throws {
        let mock = MockReachabilityMonitoring()
        let monitor = ConnectivityMonitor(monitor: mock)
        let task = Task { await monitor.observe() }

        mock.send(true)
        mock.send(false)
        try await pollUntil { monitor.isOnline == false }
        #expect(monitor.reconnects == 0)

        mock.send(true, isConstrained: true)
        try await pollUntil { monitor.isOnline == true }
        mock.send(true, isConstrained: false)
        mock.send(false)
        try await pollUntil { monitor.isOnline == false }
        #expect(monitor.reconnects == 1)

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
    func forwardsConstraintGatedOnSatisfied() async throws {
        let mock = MockReachabilityMonitoring()
        let monitor = ConnectivityMonitor(monitor: mock)
        let builder = DeviceProfileBuilder(probe: FakeCapabilityProbe())
        let task = Task { await monitor.observe(reportingConstraintTo: builder) }

        // The two ceilings are the builder's own constants, not re-typed 8/360: retuning either one
        // must not leave this test asserting a bitrate the app no longer serves.
        let clamped = DeviceProfileBuilder.lowDataBitrateCeiling
        let unclamped = DeviceProfileBuilder.lanBitrateCeiling

        // Satisfied + constrained clamps the profile bitrate.
        mock.send(true, isConstrained: true)
        #expect(await eventually { await builder.build().maxBitrate == clamped })

        // A connectivity blip (unsatisfied, constrained bit meaningless) must NOT lift the
        // clamp. The isOnline flip is the barrier proving the loop processed the element.
        mock.send(false, isConstrained: false)
        try await pollUntil { monitor.isOnline == false }
        #expect(await builder.build().maxBitrate == clamped)

        // Re-satisfaction with Low Data Mode off un-clamps.
        mock.send(true, isConstrained: false)
        #expect(await eventually { await builder.build().maxBitrate == unclamped })

        task.cancel()
        mock.finish()
    }
}

/// Polls an async predicate (the sync `waitUntil` can't await actor state like the builder's).
@MainActor
private func eventually(_ predicate: () async -> Bool) async -> Bool {
    for _ in 0..<200 {
        if await predicate() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await predicate()
}
