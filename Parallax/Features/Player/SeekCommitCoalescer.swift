import Foundation

/// Folds a burst of ±10s seek taps/clicks into ONE engine seek. Both the iOS double-tap
/// (`PlayerControlsView`) and the tvOS click-seek (`PlayerView`) accumulate an absolute
/// target and fire a single commit after a quiet interval — per-tap seeks thrash a
/// transcode and wedge the player (the click-seek lesson). Owned per-surface: the commit
/// closure routes through that surface's own seek path (`vm.commitScrubSeek` /
/// `apply(.seek)`), so this helper only owns the accumulate-then-fire-once timing.
/// Cancel-on-newer — a fresh target restarts the clock.
@MainActor
final class SeekCommitCoalescer {
    /// The quiet time after the last tap before the accumulated seek fires: long enough
    /// to fold a burst into one transcode seek, short enough to feel responsive. ONE
    /// constant across both surfaces (the tvOS swipe-scrub idle also reuses it for the
    /// same feel). Tunable on device.
    static let interval: Duration = .milliseconds(400)

    /// The accumulated absolute target (seconds), readable so a surface can base the next
    /// tap's delta on the pending destination rather than the lagging live position (a
    /// double-tap right after a drag would otherwise accumulate from the pre-scrub spot).
    private(set) var pending: Double?
    private var task: Task<Void, Never>?

    /// Accumulate `target` and (re)arm the debounce; `commit` receives the settled target
    /// after the quiet interval. A newer `schedule` cancels the pending fire.
    func schedule(_ target: Double, commit: @escaping (Double) async -> Void) {
        pending = target
        task?.cancel()
        task = Task { [self] in
            try? await Task.sleep(for: Self.interval)
            guard !Task.isCancelled, let target = pending else { return }
            pending = nil
            await commit(target)
        }
    }

    /// Fire the accumulated target NOW (leave-early) and clear it; no-op if nothing pending.
    /// The natural debounce path commits via `schedule`'s closure instead.
    func flush(commit: (Double) -> Void) {
        task?.cancel()
        guard let target = pending else { return }
        pending = nil
        commit(target)
    }

    /// Drop the pending target without committing (another seek path takes over).
    func cancel() {
        task?.cancel()
        pending = nil
    }
}
