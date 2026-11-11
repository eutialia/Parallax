import Foundation
import Observation
import ParallaxPlayback

/// The single owner of a playback engine's lifetime.
///
/// A session builds one engine and reloads reuse it, so the slot holds that engine from the
/// first load until `drain()`. Every engine installed here is torn down here, and session end
/// awaits that teardown, so none outlives the session that started it.
@MainActor
@Observable
final class EngineSlot {

    /// The engine the session is driving right now. Nil before `install(_:)` and after
    /// `drain()`.
    private(set) var current: (any PlaybackEngine)?

    /// Teardowns still running. `drain()` is the only thing that waits on them.
    @ObservationIgnored private var retirements: [Int: Task<Void, Never>] = [:]
    @ObservationIgnored private var nextRetirementID = 0

    /// An engine already in the slot is retired, never overwritten, so installing cannot leak
    /// one.
    func install(_ incoming: any PlaybackEngine) {
        guard current !== incoming else { return }
        if let outgoing = current { retire(outgoing) }
        current = incoming
    }

    /// Ends the slot: the live engine is dropped and torn down, and every teardown is awaited.
    /// Used by `stop()` and by the load-failure teardown, so "the engine is gone" and "its
    /// teardown finished" are the same moment for every caller.
    func drain() async {
        if let outgoing = current {
            current = nil
            retire(outgoing)
        }
        // Re-checked rather than awaited once: an install can retire an engine while this is
        // suspended on an earlier teardown.
        while !retirements.isEmpty {
            let pending = retirements
            retirements.removeAll()
            for task in pending.values { await task.value }
        }
    }

    private func retire(_ engine: any PlaybackEngine) {
        nextRetirementID += 1
        let id = nextRetirementID
        retirements[id] = Task { [weak self] in
            await engine.teardown()
            // A no-op when `drain()` already claimed the task.
            self?.retirements[id] = nil
        }
    }
}
