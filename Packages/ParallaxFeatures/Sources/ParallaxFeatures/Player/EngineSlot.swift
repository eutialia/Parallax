import Foundation
import Observation
import ParallaxPlayback

/// The single owner of a playback engine's lifetime.
///
/// Every engine `PlayerViewModel` builds lives here, and every engine it stops using dies
/// here. Two invariants the view model relies on and could not keep by hand:
///
/// 1. **The slot is never empty mid-session.** A rebuild installs the replacement in the
///    SAME MainActor tick the outgoing engine leaves, so `PlayerView`'s
///    `if let engine = vm.engine` host view stays mounted across the swap — with it the
///    frozen frame the reload scrim is drawn over, the freeze/unfreeze actions the view
///    pushed up, and (on the VLC→VLC path) the drawable the new player re-points to.
///    A `nil` in that window unmounts the host, and the user watches black behind the
///    scrim for as long as a VLC teardown takes.
/// 2. **A retired engine is silent immediately and gone eventually.** `endAudio()` — the
///    terminal cut, not the resumable `silence()` — is awaited before the swap, because
///    two decoders feeding one output is the audible defect. `teardown()` is the slow,
///    invisible half (VLC's runs multi-second on a parked SMB read), so it goes into a
///    tracked retirement task instead of onto the critical path. `drain()` is what makes
///    that safe: session end awaits every retirement, so no teardown outlives the session
///    that started it.
///
/// Trailing beats from a retiring engine are the price of (2), and
/// `PlayerViewModel.handle(_:from:)` pays it with an identity guard: a state already
/// pulled from the outgoing stream can still be waiting for its MainActor hop when the
/// replacement is installed.
@MainActor
@Observable
final class EngineSlot {

    /// The engine the session is driving right now. Nil only before the first
    /// `swap(to:)` and after `drain()`.
    private(set) var current: (any PlaybackEngine)?

    /// Teardowns still running, keyed so each can retire itself without disturbing the
    /// others' order. `drain()` is the only thing that waits on them.
    @ObservationIgnored private var retirements: [Int: Task<Void, Never>] = [:]
    @ObservationIgnored private var nextRetirementID = 0

    /// Installs `incoming` as the live engine, cutting the outgoing engine's audio first
    /// and retiring it afterwards.
    ///
    /// The two halves are deliberately split across the swap: the audio cut is awaited
    /// (fast, and the defect it prevents is audible), the teardown is not (slow, and the
    /// only thing waiting on it would be the frame on screen). Between the cut and the
    /// install there is no suspension, so no observer can see the slot empty.
    func swap(to incoming: any PlaybackEngine) async {
        guard current !== incoming else { return }
        await current?.endAudio()
        // Re-read after the suspension: a swap that raced this one owns whatever is here
        // now, and retiring a stale capture would leak the engine actually installed.
        let outgoing = current
        current = incoming
        if let outgoing, outgoing !== incoming { retire(outgoing) }
    }

    /// Ends the slot: the live engine is dropped and torn down like any retirement, and
    /// every retirement — its own included — is awaited. The session-end counterpart of
    /// `swap(to:)`, used by `stop()` and by the load-failure teardown, so "the engine is
    /// gone" and "its teardown finished" are the same moment for every caller.
    func drain() async {
        if let outgoing = current {
            current = nil
            retire(outgoing)
        }
        // Re-checked rather than awaited once: a teardown can be scheduled by a swap that
        // lands while we are suspended on an earlier one.
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
            // A no-op when `drain()` already claimed the task; it keeps a long session's
            // retirement table from growing one entry per track switch.
            self?.retirements[id] = nil
        }
    }
}
