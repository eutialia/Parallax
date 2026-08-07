import Foundation

/// A hand-driven stand-in for the graveyard's release fuse.
///
/// The production fuse is minutes long (`2 × (operation timeout + margin)`), so
/// a test can neither wait it out nor shorten it without re-typing the very math it is checking.
/// Injected as the pool's `fuseSleep`, this records what was asked for and only returns when the test
/// fires it — the same "drive the clock, never sleep" discipline as `FakeClock` and `AsyncGate`.
actor FakeFuseTimer {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var arrivalWaiters: [CheckedContinuation<Void, Never>] = []

    /// Every fuse duration the graveyard has asked to wait out, in request order.
    private(set) var requested: [Duration] = []

    /// The graveyard's `sleep`: parks until `fire()`.
    func wait(_ duration: Duration) async {
        requested.append(duration)
        let arrived = arrivalWaiters
        arrivalWaiters = []
        for waiter in arrived { waiter.resume() }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            waiters.append(continuation)
        }
    }

    /// Elapses every pending fuse.
    func fire() {
        let parked = waiters
        waiters = []
        for waiter in parked { waiter.resume() }
    }

    /// Suspends until at least `count` fuses have been armed — proof the production code reached the
    /// fuse rather than a guess about scheduling.
    func awaitRequests(_ count: Int = 1) async {
        while requested.count < count {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                arrivalWaiters.append(continuation)
            }
        }
    }
}
