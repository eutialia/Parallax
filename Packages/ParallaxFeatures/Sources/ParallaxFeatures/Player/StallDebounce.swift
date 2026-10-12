import Observation

/// The mid-stream stall flag behind the light buffering scrim. Debounced ~400ms so the
/// sub-second waits of a healthy in-buffer seek don't flash the scrim; cleared edge-on by the
/// next playing/paused beat.
@Observable
@MainActor
final class StallDebounce {
    private(set) var isStalled = false
    @ObservationIgnored private var debounceTask: Task<Void, Never>?
    @ObservationIgnored private let clock: any Clock<Duration>

    init(clock: any Clock<Duration>) {
        self.clock = clock
    }

    isolated deinit {
        debounceTask?.cancel()
    }

    /// The engine is waiting for media: raise the flag if it is still waiting 400ms from now.
    func arm() {
        guard !isStalled, debounceTask == nil else { return }
        debounceTask = Task { [weak self, clock] in
            try? await clock.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.isStalled = true
            self?.debounceTask = nil
        }
    }

    /// A wait known to be real (a seek fetch): raise the flag without the debounce.
    func raiseNow() {
        debounceTask?.cancel()
        debounceTask = nil
        isStalled = true
    }

    func clear() {
        debounceTask?.cancel()
        debounceTask = nil
        isStalled = false
    }
}
