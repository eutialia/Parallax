import Testing
import Foundation
@testable import ParallaxPlayback

@Suite("LoadWatchdog")
@MainActor
struct LoadWatchdogTests {

    /// Polls `condition` up to ~2s so the timing assertions don't flake under heavy MainActor
    /// contention (the full suite runs many @MainActor async tests; a fixed wall-clock wait races
    /// the watchdog's own Task). Returns as soon as it's true.
    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<80 where !condition() {
            try? await Task.sleep(for: .milliseconds(25))
        }
    }

    @Test("fires onTimeout when armed and never disarmed")
    func firesWhenNotDisarmed() async {
        let wd = LoadWatchdog(timeout: .milliseconds(50))
        var fired = false
        wd.arm { fired = true }
        await waitUntil { fired }
        #expect(fired)
    }

    @Test("disarm cancels the pending timeout")
    func disarmCancels() async {
        let wd = LoadWatchdog(timeout: .milliseconds(50))
        var fired = false
        wd.arm { fired = true }
        wd.disarm()
        // Well past the timeout with margin — a disarmed timer must never fire.
        try? await Task.sleep(for: .milliseconds(400))
        #expect(!fired)
    }

    @Test("re-arming supersedes the previous timer (only the latest fires once)")
    func rearmSupersedes() async {
        let wd = LoadWatchdog(timeout: .milliseconds(50))
        var count = 0
        wd.arm { count += 1 }
        wd.arm { count += 1 }   // supersedes the first — it must be cancelled
        await waitUntil { count > 0 }
        try? await Task.sleep(for: .milliseconds(150))   // give a stray first-timer a chance to (wrongly) fire
        #expect(count == 1)
    }
}
