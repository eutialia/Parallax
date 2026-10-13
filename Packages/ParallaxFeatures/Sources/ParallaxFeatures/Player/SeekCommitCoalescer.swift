import Foundation

/// Folds a burst of ±10s seek taps/clicks into ONE engine seek. Both the iOS double-tap
/// and the tvOS click-seek accumulate an absolute
/// target and fire a single commit after a quiet interval — per-tap seeks thrash a
/// transcode and wedge the player (the click-seek lesson). The player view model owns one and
/// exposes it as `scheduleSeek` / `flushPendingSeek` / `cancelPendingSeek`, so this helper only
/// owns the accumulate-then-fire-once timing.
/// Cancel-on-newer — a fresh target restarts the clock.
@MainActor
public final class SeekCommitCoalescer {
    /// The quiet time after the last tap before the accumulated seek fires: long enough
    /// to fold a burst into one transcode seek, short enough to feel responsive. ONE
    /// constant across both surfaces (the tvOS swipe-scrub idle also reuses it for the
    /// same feel). Tunable on device.
    public static let interval: Duration = .milliseconds(400)

    /// The accumulated absolute target (seconds), readable so a surface can base the next
    /// tap's delta on the pending destination rather than the lagging live position (a
    /// double-tap right after a drag would otherwise accumulate from the pre-scrub spot).
    public private(set) var pending: Double?
    private var task: Task<Void, Never>?
    private let clock: any Clock<Duration>

    init(clock: any Clock<Duration>) {
        self.clock = clock
    }

    /// Accumulate `target` and (re)arm the debounce; `commit` receives the settled target
    /// after the quiet interval. A newer `schedule` cancels the pending fire.
    public func schedule(_ target: Double, commit: @escaping (Double) async -> Void) {
        pending = target
        task?.cancel()
        task = Task { [self, clock] in
            try? await clock.sleep(for: Self.interval)
            guard !Task.isCancelled, let target = pending else { return }
            pending = nil
            await commit(target)
        }
    }

    /// Fire the accumulated target NOW (leave-early) and clear it; no-op if nothing pending.
    /// The natural debounce path commits via `schedule`'s closure instead.
    public func flush(commit: (Double) -> Void) {
        task?.cancel()
        guard let target = pending else { return }
        pending = nil
        commit(target)
    }

    /// Drop the pending target without committing (another seek path takes over).
    public func cancel() {
        task?.cancel()
        pending = nil
    }
}
