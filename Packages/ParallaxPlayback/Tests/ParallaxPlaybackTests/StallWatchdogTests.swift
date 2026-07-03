import Testing
import Foundation
@testable import ParallaxPlayback

@Suite("StallWatchdog")
@MainActor
struct StallWatchdogTests {

    /// Polls `condition` up to ~2s so the timing assertions don't flake under heavy MainActor
    /// contention (the full suite runs many @MainActor async tests; a fixed wall-clock wait races
    /// the watchdog's own Task). Returns as soon as it's true.
    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<80 where !condition() {
            try? await Task.sleep(for: .milliseconds(25))
        }
    }

    @Test("fires onExpiry when armed and never disarmed")
    func firesWhenNotDisarmed() async {
        var fired = false
        let wd = StallWatchdog(deadline: .milliseconds(50)) { fired = true }
        wd.arm()
        await waitUntil { fired }
        #expect(fired)
    }

    @Test("disarm cancels the pending timeout")
    func disarmCancels() async {
        var fired = false
        let wd = StallWatchdog(deadline: .milliseconds(50)) { fired = true }
        wd.arm()
        wd.disarm()
        // Well past the deadline with margin — a disarmed timer must never fire.
        try? await Task.sleep(for: .milliseconds(400))
        #expect(!fired)
    }

    @Test("re-arming supersedes the previous timer (only the latest fires once)")
    func rearmSupersedes() async {
        var count = 0
        let wd = StallWatchdog(deadline: .milliseconds(50)) { count += 1 }
        wd.arm()
        wd.arm()   // supersedes the first — it must be cancelled, not fire a second time
        await waitUntil { count > 0 }
        try? await Task.sleep(for: .milliseconds(150))   // give a stray first-timer a chance to (wrongly) fire
        #expect(count == 1)
    }

    @Test("disarm after expiry is a harmless no-op")
    func disarmAfterExpiry() async {
        var count = 0
        let wd = StallWatchdog(deadline: .milliseconds(50)) { count += 1 }
        wd.arm()
        await waitUntil { count > 0 }
        wd.disarm()   // already fired — must not crash or re-fire
        try? await Task.sleep(for: .milliseconds(150))
        #expect(count == 1)
    }
}
