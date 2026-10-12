import Foundation
import Observation
import ParallaxCore
import ParallaxFileBrowse
import ParallaxJellyfin

/// One saved SMB server's settings, behind `SMBServerSettingsView`: the live share list merged with
/// the persisted selection, share toggles persisted in tap order, and removal of the whole server.
@Observable
@MainActor
public final class SMBServerSettingsModel {
    public enum LoadState: Equatable {
        case loading
        case loaded([SMBShare])
        /// `offersPasswordRecovery` marks the failures the saved password can explain — a lost
        /// Keychain slot, or a server that refused the sign-in. Those get the "Enter Password…"
        /// row beside Retry; a plain unreachable host doesn't, since re-typing a correct password
        /// wouldn't help.
        case failed(String, offersPasswordRecovery: Bool)
    }

    /// Where focus should land once the shares group settles.
    public enum ShareFocusTarget: Equatable {
        case row(String)
        case retry
    }

    public let id: ServerID
    public let data: SMBServerData
    public private(set) var loadState = LoadState.loading
    /// The set of share names currently toggled on (synced from persisted data on load).
    public private(set) var enabledShares: Set<String> = []

    private let makeLister: (SMBServerRef) async throws -> any SMBLister
    private let serverStore: ServerStore
    private let router: AppRouter
    private let routeToSources: () async -> Void
    /// Serialises share-toggle writes so rapid taps persist in tap order — an unordered `Task` per
    /// tap can let a stale snapshot land last, desyncing the store from the on-screen circles.
    private var saveTask: Task<Void, Never>?
    /// Monotonic token so only the LATEST share load may write state. Retry stays tappable while a
    /// load runs, so two loads can overlap — and they resolve in arrival order, not start order, so
    /// without this an older answer can land last and show a stale list (or a failure the newer,
    /// successful load already cleared).
    private var loadGeneration = 0

    init(
        id: ServerID,
        data: SMBServerData,
        makeLister: @escaping (SMBServerRef) async throws -> any SMBLister,
        serverStore: ServerStore,
        router: AppRouter,
        routeToSources: @escaping () async -> Void
    ) {
        self.id = id
        self.data = data
        self.makeLister = makeLister
        self.serverStore = serverStore
        self.router = router
        self.routeToSources = routeToSources
    }

    public func loadShares() async {
        loadGeneration += 1
        let generation = loadGeneration
        loadState = .loading
        let host = data.host
        do {
            let fetched = try await makeLister(SMBServerRef(id: id, data: data)).listShares()
            let sorted = fetched.sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
            // Seed the toggles from the LIVE store, not the navigation snapshot: the server is
            // captured when the row is tapped and the parent's list isn't refreshed on a toggle, so
            // re-entering this screen after toggling would otherwise revert the circles to the
            // stale snapshot.
            let persisted = await persistedShares()
            guard generation == loadGeneration, !Task.isCancelled else { return }
            enabledShares = persisted
            loadState = .loaded(sorted)
        } catch {
            // A disappearing view cancels this task; its error must not paint a stale failure state
            // over whatever the next appearance loads.
            guard !Task.isCancelled else { return }
            // One classification for both throw sites: makeLister's pre-flight already yields a
            // typed AppError (lost Keychain slot — never reached the server), and listShares' raw
            // POSIX failures go through the shared mapper. Either way, auth-shaped faults get the
            // credential recovery instead of a generic host message that reads as connectivity.
            let appError = (error as? AppError) ?? SMBFileSource.mapShareListError(error, host: host)
            let message: String
            // Both auth shapes are recoverable in place: the slot was lost, or the stored password
            // is stale. Either way the fix is re-entering it, not deleting the server.
            var offersPasswordRecovery = true
            switch appError {
            case .auth(.credentialUnavailable):
                message = appError.userMessage
            case .auth:
                message = "\(host) rejected the sign-in. Enter the password again to reconnect."
            default:
                message = "Couldn't load shares from \(host)."
                offersPasswordRecovery = false
            }
            guard generation == loadGeneration else { return }
            loadState = .failed(message, offersPasswordRecovery: offersPasswordRecovery)
        }
    }

    public func toggle(_ name: String) {
        let wasOn = enabledShares.contains(name)
        if wasOn { enabledShares.remove(name) } else { enabledShares.insert(name) }
        let snapshot = enabledShares.sorted()
        let (id, store, router) = (id, serverStore, router)
        // Chain off the previous write so concurrent toggles persist in tap order — an independent
        // Task per tap isn't ordered, so a stale snapshot could land last and desync the store.
        let previous = saveTask
        saveTask = Task {
            await previous?.value
            do {
                try await store.setShares(snapshot, for: id)
                // The source set is unchanged, so no fingerprint sees a share change: bump so the
                // sidebar rebuilds its merged library list now.
                router.bumpLibraryRevision()
            } catch {
                // Persist failed — revert the optimistic toggle so the circle matches what's stored.
                if wasOn { enabledShares.insert(name) } else { enabledShares.remove(name) }
            }
        }
    }

    /// Removes the server, its Keychain password and its libraries, then re-routes: removing the
    /// last source falls back to login.
    public func remove() async {
        do {
            try await serverStore.remove(id)
        } catch {
            Log.persistence.error("removing SMB server \(self.id.rawValue) failed: \(error.localizedDescription)")
        }
        await routeToSources()
    }

    /// The shares currently persisted for this server, read fresh from the store (the source of
    /// truth). Falls back to the navigation snapshot if the server was removed out from under us.
    private func persistedShares() async -> Set<String> {
        let current = await serverStore.servers.first { $0.id == id }
        if case .smb(let d) = current?.kind { return Set(d.shares) }
        return Set(data.shares)
    }

    /// Where focus should land for a given `loadState` — the single place that maps state to a
    /// focus target. Static and fully parameterised so the whole mapping is a pure function.
    public static func focusTarget(for state: LoadState, enabled: Set<String>) -> ShareFocusTarget? {
        switch state {
        case .loading: return nil
        case .loaded(let shares): return firstShareRow(live: shares, enabled: enabled)
        case .failed: return .retry
        }
    }

    /// The group's first focusable row after a successful load: a live share, else the leading
    /// unavailable row. Nil when the group renders only the "No shares found" footer — nothing to
    /// focus, so focus stays where the engine left it rather than being yanked somewhere arbitrary.
    static func firstShareRow(live shares: [SMBShare], enabled: Set<String>) -> ShareFocusTarget? {
        let name = shares.first?.name ?? unavailableShares(enabled: enabled, live: shares).first
        return name.map(ShareFocusTarget.row)
    }

    /// The enabled-but-absent share names: persisted/enabled shares the live `listShares()` no longer
    /// returns (removed or renamed server-side). Sorted for a stable row order. Rendered as
    /// "unavailable" rows so the user can switch them off and drop the dead library — without this they
    /// stay invisible in settings yet mounted as a failing sidebar tab. NOT auto-pruned: this is only
    /// computed in the `.loaded` state, so a transient connect blip (which surfaces `.failed`) never
    /// silently drops a momentarily-missing share.
    public static func unavailableShares(enabled: Set<String>, live: [SMBShare]) -> [String] {
        enabled.subtracting(live.map(\.name)).sorted()
    }
}
