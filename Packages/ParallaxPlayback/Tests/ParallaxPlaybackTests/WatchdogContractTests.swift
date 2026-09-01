import Testing
import Foundation
@testable import ParallaxPlayback

/// `LoadWatchdog` (bounds the load) and `StallWatchdog` (bounds a mid-playback stall)
/// are the same one-shot timer with different callback plumbing, and their two suites
/// were byte-for-byte duplicates. One contract, run against both.
///
/// TIMING NOTE: both are thin wrappers over `Task.sleep`, which has no injection point
/// short of threading a `Clock` through — and a hand-rolled test clock trades this
/// suite's (bounded, poll-based) waits for its own scheduling races. So the timers run
/// on real time with a deliberately small 50ms deadline: the "did fire" assertions poll
/// instead of sleeping a fixed span, and only the two "must NOT fire" assertions need a
/// real margin.
enum WatchdogKind: String, CaseIterable, CustomTestStringConvertible {
    case load
    case stall

    var testDescription: String { rawValue }

    /// Builds the watchdog and returns its arm/disarm pair. `LoadWatchdog` takes the
    /// callback at `arm`, `StallWatchdog` at `init` and the session at `arm`; the adapter
    /// hides that difference so the contract reads the same for both.
    @MainActor
    func make(deadline: Duration, onFire: @escaping @MainActor () -> Void)
    -> (arm: () -> Void, disarm: () -> Void) {
        switch self {
        case .load:
            let wd = LoadWatchdog(timeout: deadline)
            return ({ wd.arm(onTimeout: onFire) }, { wd.disarm() })
        case .stall:
            let wd = StallWatchdog(deadline: deadline, onExpiry: { _ in onFire() })
            return ({ wd.arm(for: .none) }, { wd.disarm() })
        }
    }
}

@Suite("Watchdog contract")
@MainActor
struct WatchdogContractTests {

    private let deadline = Duration.milliseconds(50)

    /// Polls up to ~2s so a busy MainActor (the suite runs many async tests in parallel)
    /// can't turn a slow schedule into a failure. Returns as soon as the condition holds.
    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<80 where condition() == false {
            try? await Task.sleep(for: .milliseconds(25))
        }
    }

    @Test("an armed watchdog fires once the deadline elapses", arguments: WatchdogKind.allCases)
    func firesWhenNotDisarmed(kind: WatchdogKind) async {
        var fired = false
        let wd = kind.make(deadline: deadline) { fired = true }
        wd.arm()
        await waitUntil { fired }
        #expect(fired)
    }

    /// The whole point: the first sign of life (a real beat, `.ready`, or teardown)
    /// must make the pending failure unreachable.
    @Test("disarm cancels the pending deadline for good", arguments: WatchdogKind.allCases)
    func disarmCancels(kind: WatchdogKind) async {
        var fired = false
        let wd = kind.make(deadline: deadline) { fired = true }
        wd.arm()
        wd.disarm()
        try? await Task.sleep(for: .milliseconds(400))   // 8× the deadline
        #expect(fired == false)
    }

    /// Re-arming is how the engines reset the clock on every fresh `.buffering` beat —
    /// it must supersede the previous timer, not stack a second one.
    @Test("re-arming supersedes the previous timer so it fires exactly once",
          arguments: WatchdogKind.allCases)
    func rearmSupersedes(kind: WatchdogKind) async {
        var count = 0
        let wd = kind.make(deadline: deadline) { count += 1 }
        wd.arm()
        wd.arm()
        await waitUntil { count > 0 }
        try? await Task.sleep(for: .milliseconds(150))   // let a stray first timer misfire
        #expect(count == 1)
    }

    /// The engines disarm on every transport beat without tracking whether the deadline
    /// already blew, so a post-expiry disarm has to be inert.
    @Test("disarm after expiry neither crashes nor re-fires", arguments: WatchdogKind.allCases)
    func disarmAfterExpiry(kind: WatchdogKind) async {
        var count = 0
        let wd = kind.make(deadline: deadline) { count += 1 }
        wd.arm()
        await waitUntil { count > 0 }
        wd.disarm()
        try? await Task.sleep(for: .milliseconds(150))
        #expect(count == 1)
    }

    /// Disarming a watchdog that was never armed happens on every teardown of a session
    /// that failed before `.loading`.
    @Test("disarm before arm is a no-op", arguments: WatchdogKind.allCases)
    func disarmBeforeArmIsInert(kind: WatchdogKind) async {
        var fired = false
        let wd = kind.make(deadline: deadline) { fired = true }
        wd.disarm()
        try? await Task.sleep(for: .milliseconds(150))
        #expect(fired == false)
    }
}
