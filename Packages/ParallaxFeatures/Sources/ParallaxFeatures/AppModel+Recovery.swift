import Observation
import ParallaxCore

/// The screens that repair themselves, held weakly: a screen's view model lives exactly as long as
/// its view stays mounted, and a popped screen has nothing left to repair.
@MainActor
final class RecoverableScreens {
    private struct Entry {
        let id: ObjectIdentifier
        let isAlive: @MainActor () -> Bool
        let isStalled: @MainActor () -> Bool
        let recover: @MainActor () async -> Void
    }

    private var entries: [Entry] = []

    /// Idempotent per model, so a screen may register on every load.
    func track<Model: AnyObject & Sendable>(
        _ model: Model,
        isStalled: @escaping @MainActor (Model) -> Bool,
        recover: @escaping @MainActor (Model) async -> Void
    ) {
        entries.removeAll { !$0.isAlive() }
        let id = ObjectIdentifier(model)
        guard !entries.contains(where: { $0.id == id }) else { return }
        entries.append(Entry(
            id: id,
            isAlive: { [weak model] in model != nil },
            isStalled: { [weak model] in model.map(isStalled) ?? false },
            recover: { [weak model] in if let model { await recover(model) } }
        ))
    }

    /// The repair of every live screen that is stalled right now.
    var repairs: [@MainActor () async -> Void] {
        entries.filter { $0.isAlive() && $0.isStalled() }.map(\.recover)
    }
}

struct WeakLevel {
    weak var level: SMBBrowseViewModel?
}

extension AppModel {
    /// Screens stuck on a blocking error reload by themselves when the network returns, or when the
    /// app returns from the background with a network path already up. A healthy screen is never
    /// re-pulled. A return while still offline needs nothing: the reconnect edge fires when the path
    /// comes back.
    func recoverStalledScreens() async {
        var seen = RecoveryEdges()
        for await edges in Observations({
            RecoveryEdges(reconnects: self.connectivity.reconnects, foregroundReturns: self.lifecycle.foregroundReturns)
        }) {
            let reconnected = edges.reconnects != seen.reconnects
            let returned = edges.foregroundReturns != seen.foregroundReturns && connectivity.isOnline
            seen = edges
            guard reconnected || returned else { continue }
            await repairStalledScreens()
        }
    }

    private struct RecoveryEdges: Equatable {
        var reconnects = 0
        var foregroundReturns = 0
    }

    private func repairStalledScreens() async {
        await withDiscardingTaskGroup { group in
            // Home and the library list are app-wide singletons, so no view has to mount them.
            if let home, home.needsOfflineRepair {
                group.addTask { await home.recoverFromOffline() }
            }
            if !libraries.failedSourceIDs.isEmpty {
                group.addTask { await self.loadLibraries() }
            }
            for repair in recoverableScreens.repairs {
                group.addTask { await repair() }
            }
        }
    }

    /// After sleep every pooled SMB socket is dead: a genuine return from the background flushes the
    /// idle corpses first, then re-lists the level on screen with its content still up. Flush then
    /// refresh, so the re-list can't check out a connection that is already a corpse. A stalled
    /// level is `recoverStalledScreens`'s, not this flow's.
    ///
    /// Which levels to re-list is decided at the edge, before the flush suspends: by the time it
    /// resumes, `recoverStalledScreens` may already have listed a stalled level back to health on
    /// the same edge, and a re-list then would list it twice.
    ///
    /// Held while the player is up: on iOS the player is an overlay, so the level stays mounted and
    /// a flush plus re-list would run over the very uplink the stream is using.
    func refreshSMBLevelsOnForeground() async {
        var seen = 0
        for await returns in Observations({ self.lifecycle.foregroundReturns }) where returns != seen {
            seen = returns
            guard !playback.isPlayerPresent else { continue }
            let onScreen = smbLevels.compactMap(\.level).filter(\.isOnScreen)
            guard !onScreen.isEmpty else { continue }
            let healthy = onScreen.filter { $0.setup == .open && !$0.isStalled && !$0.isLoading }
            await services.flushSMBConnections()
            healthy.forEach { $0.refresh() }
        }
    }

    func trackSMBLevel(_ level: SMBBrowseViewModel) {
        smbLevels.removeAll { $0.level == nil }
        smbLevels.append(WeakLevel(level: level))
        recoverableScreens.track(level, isStalled: { $0.isStalled }, recover: { await $0.recover() })
    }
}
