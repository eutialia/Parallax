/// A hand-driven latch for tests that need to observe or hold an `await` mid-flight.
///
/// Replaces wall-clock sleeps in the suites that must interleave with production `await`s: the
/// code under test calls `pass()`, and the test decides when (or whether) that call proceeds. A
/// test can also wait for the *arrival* — proof the production code actually reached the
/// suspension point — instead of guessing with a sleep.
actor AsyncGate {
    private var isOpen: Bool
    private var arrivals = 0
    private var passWaiters: [CheckedContinuation<Void, Never>] = []
    private var arrivalWaiters: [CheckedContinuation<Void, Never>] = []

    /// - Parameter open: `true` (default) lets callers through immediately; `false` holds them.
    init(open: Bool = true) {
        isOpen = open
    }

    /// Called from the code under test. Records the arrival, then returns immediately while open
    /// or suspends until `open()` while closed.
    func pass() async {
        arrivals += 1
        let waiting = arrivalWaiters
        arrivalWaiters = []
        for waiter in waiting { waiter.resume() }
        guard isOpen == false else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            passWaiters.append(continuation)
        }
    }

    /// Holds every subsequent `pass()`.
    func close() {
        isOpen = false
    }

    /// Releases everyone parked in `pass()` and lets future callers straight through.
    func open() {
        isOpen = true
        let waiting = passWaiters
        passWaiters = []
        for waiter in waiting { waiter.resume() }
    }

    /// How many callers have reached `pass()` so far. Polled (rather than awaited) by tests that
    /// must assert an arrival count did NOT grow — `awaitArrivals` can only wait for one to.
    var arrivalCount: Int { arrivals }

    /// Suspends until at least `count` callers have reached `pass()`.
    func awaitArrivals(_ count: Int = 1) async {
        while arrivals < count {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                arrivalWaiters.append(continuation)
            }
        }
    }
}
