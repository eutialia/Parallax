import Foundation

/// One deadline the engine arms when it starts waiting on AVPlayer and disarms at the first
/// sign of life. AVPlayer has no timeout of its own for either wait the engine bounds: an item
/// that never turns ready stays `.unknown`, and a stalled one retries a dead socket in
/// `.waitingToPlayAtSpecifiedRate` for as long as it is left to.
///
/// Arming again replaces the pending deadline, so only the latest one fires.
@MainActor
final class Watchdog {
    private let deadline: Duration
    private let clock: any Clock<Duration>
    private var task: Task<Void, Never>?

    init(deadline: Duration, clock: any Clock<Duration>) {
        self.deadline = deadline
        self.clock = clock
    }

    func arm(onExpiry: @escaping @MainActor () -> Void) {
        task?.cancel()
        task = Task { [deadline, clock] in
            try? await clock.sleep(for: deadline)
            guard !Task.isCancelled else { return }
            onExpiry()
        }
    }

    func disarm() {
        task?.cancel()
        task = nil
    }
}
