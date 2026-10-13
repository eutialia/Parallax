import Foundation
import Observation
import os
import ParallaxCore
import ParallaxJellyfin

@Observable
@MainActor
public final class JellyfinSearchViewModel {
    public enum LoadState: Equatable {
        case idle, loading, loaded(AggregatedSearchResults), failed(String)
    }

    /// Bound straight to the search field. The model exists before the first keystroke, so nothing
    /// typed while the providers are still being built is lost.
    public var query: String = "" {
        didSet {
            if query != oldValue {
                Task { await debouncer.update(query) }
            }
        }
    }

    public var scope: SearchScope = .all {
        didSet {
            if scope != oldValue {
                Task { await debouncer.update(query) }
            }
        }
    }

    public private(set) var state: LoadState = .idle
    /// True while a refine query is in flight on top of existing results — drives an
    /// inline indicator instead of tearing the whole results page down.
    public private(set) var isSearching = false

    /// Showing the blocking full-screen failure — the state an offline→online recovery should
    /// re-run the last query for. Offline recovery acts on it.
    public var isStalled: Bool { if case .failed = state { true } else { false } }
    /// A search session is on screen (loading/loaded/failed) — false only at idle. Drives the
    /// scope row's visibility so it enters/leaves in the same motion as the content swap
    /// (both flip on the same debounced state transition, unlike the raw keystroke).
    public var hasActiveSearch: Bool { state != .idle }
    /// Every searchable source. Sources that can't answer yet (SMB, until it has an index) report
    /// `canSearch == false` and are filtered out here, so they contribute nothing rather than
    /// erroring — see `SearchProviding`. `nil` until the first `refreshProviders()` lands: a query
    /// that runs before then has no sources to ask, which is not the same as having none.
    private var providers: [any SearchProviding]?
    private let app: AppModel
    private let debouncer: AsyncDebouncer<String>
    private var consumerTask: Task<Void, Never>?
    private var changesTask: Task<Void, Never>?
    /// Monotonic token so only the LATEST query may write results. The consumer loop serializes
    /// debounced queries, but `retry()` calls `runQuery` directly (offline recovery), so a recovery
    /// query can overlap an in-flight debounced one (MainActor is reentrant across `await search`).
    /// Last query wins — mirrors `LibraryGridViewModel`/`SMBBrowseViewModel`'s generation guard.
    private var queryGeneration = 0

    /// The sources this model searches, in order — see `matches(_:)`.
    var sourceIDs: [MediaSourceID] { (providers ?? []).map(\.source.sourceID) }

    /// Whether this model already answers for exactly `candidates`. The `canSearch` filter is
    /// applied here so the rebuild test can't drift from the filtering `refreshProviders()` stores —
    /// otherwise a source that reports `canSearch == false` (SMB, until it has an index) would never
    /// compare equal and the providers would be rebuilt on every token.
    func matches(_ candidates: [any SearchProviding]) -> Bool {
        sourceIDs == candidates.filter(\.canSearch).map(\.source.sourceID)
    }

    public init(app: AppModel) {
        self.app = app
        let clock = app.clock
        debouncer = AsyncDebouncer<String>(delay: .milliseconds(350)) { try await clock.sleep(for: $0) }
        app.recoverableScreens.track(self, isStalled: { $0.isStalled }, recover: { await $0.retry() })
    }

    /// The screen's lifetime: rebuilds the providers on every source change. Search aggregates
    /// EVERY signed-in server, so adding or removing one must rebuild the list, and adding a second
    /// server never moves the active id.
    public func run() async {
        await app.forEachSourceChange { await self.refreshProviders() }
    }

    /// Rebuilds the providers from the servers signed in right now. A new set starts a new search
    /// session: the scope goes back to All, and a query on screen re-runs against the new servers.
    private func refreshProviders() async {
        start()
        let candidates = await JellyfinSearchProvider.all(
            for: await app.services.serverStore.sessions,
            repoFactory: app.services.jellyfinLibraryRepoFactory
        )
        if providers != nil, candidates.isEmpty || matches(candidates) { return }
        providers = candidates.filter(\.canSearch)
        if scope != .all {
            // Its `didSet` re-runs the query.
            scope = .all
        } else if !query.isEmpty {
            await runQuery(query)
        }
    }

    /// Spawned here rather than in `init`: SwiftUI may build the view, and so this model, more
    /// than once before keeping one.
    private func start() {
        guard consumerTask == nil else { return }
        // Own the iterating Task; cancelled below alongside the search consumer loop.
        changesTask = app.userDataActions.subscribe { [weak self] change in
            self?.apply(change)
        }
        // Capture the stream by value (it doesn't retain the debouncer actor)
        // and keep `self` weak across the whole loop. Promoting weak→strong
        // with `guard let self` here would pin the VM for the lifetime of the
        // for-await — and since `consumerTask` is stored on the VM, that's a
        // self→consumerTask→self retain cycle that leaks the VM (plus its
        // repo and last results) on every server switch.
        let stream = debouncer.stream
        consumerTask = Task { [weak self] in
            for await q in stream {
                await self?.runQuery(q)
            }
        }
    }

    isolated deinit {
        // Belt-and-suspenders: the debouncer's own deinit finishes the stream
        // (ending the loop), but cancelling here makes teardown immediate.
        // `isolated deinit` (SE-0371) runs teardown on the MainActor so it can
        // touch the actor-isolated `consumerTask`.
        consumerTask?.cancel()
        changesTask?.cancel()
    }

    /// Patch a matching result's `userData` in place via `change.merged(into:)` — never the
    /// raw payload, since a played-operation response's favorite field (or a favorite
    /// response's played/position fields) is a DTO-boundary default, not real state. Updates
    /// the watched badge / favorite UI automatically since `MediaTile` reads the item.
    /// `SearchResults`' three arrays are `let`, so a match rebuilds the whole struct; `state`
    /// stays `.loaded` throughout. Early-outs when none of the three arrays hold `itemID`,
    /// skipping the rebuild.
    private func apply(_ change: UserDataActions.Change) {
        guard case .loaded(let results) = state else { return }
        // Matched on (source, itemID): results now mix servers, so an id-only match could patch a
        // same-id item belonging to a different server.
        guard results.contains(itemID: change.itemID, source: change.source) else { return }
        state = .loaded(results.patching(itemID: change.itemID, source: change.source) {
            $0.withUserData(change.merged(into: $0.userData))
        })
    }

    /// Re-run the current query after an offline→online recovery (search has no `load()`; the
    /// query drives everything). A no-op for an empty field — there's nothing to re-search.
    public func retry() async {
        await runQuery(query)
    }

    private func runQuery(_ q: String) async {
        queryGeneration += 1
        let generation = queryGeneration
        let trimmed = q.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            state = .idle
            isSearching = false
            // A scope outlives its search session otherwise: search "Batman" scoped to Episodes,
            // clear, search "Dune" — with the scope control hidden at idle, the stale Episodes scope
            // would silently narrow the new search. Ending a session resets to All.
            if scope != .all { scope = .all }
            return
        }
        // Full-page spinner only on the FIRST search. Once results are on screen, keep
        // them mounted while refining (so the ScrollView keeps its offset and the main
        // actor isn't busy rebuilding the whole grid on every keystroke) and show a
        // small inline indicator via `isSearching` instead.
        if case .loaded = state {} else { state = .loading }
        // `refreshProviders()` re-runs the query once the sources land.
        guard let providers else { return }
        isSearching = true
        // A newer query owns `isSearching` once it starts, so only the latest clears it.
        defer { if generation == queryGeneration { isSearching = false } }
        // Fan out across every searchable source concurrently. Each source fails INDEPENDENTLY —
        // a dead server contributes nothing rather than failing the whole search, which is the
        // difference between "one server is unreachable" and "search is broken". `.failed` only
        // when EVERY source threw.
        let currentScope = scope
        let perSource = await withTaskGroup(
            of: (Int, (source: LibrarySource, results: SearchResults)?).self
        ) { group in
            for (index, provider) in providers.enumerated() {
                // Read out here: `source` (and its `displayName`) are synchronous MainActor-isolated
                // reads, so touching them inside the child task is an isolation violation.
                let source = provider.source
                let name = source.displayName
                group.addTask {
                    do {
                        return (index, (source, try await provider.search(trimmed, scope: currentScope)))
                    } catch {
                        Log.ui.error("Search failed for \(name): \(error.networkDiagnostic)")
                        return (index, nil)
                    }
                }
            }
            var out: [(Int, (source: LibrarySource, results: SearchResults)?)] = []
            for await result in group { out.append(result) }
            return out.sorted { $0.0 < $1.0 }.map(\.1)
        }
        guard generation == queryGeneration else { return }
        let answered = perSource.compactMap { $0 }
        guard !answered.isEmpty else {
            state = providers.isEmpty ? .loaded(.empty) : .failed("Parallax couldn't reach your servers.")
            return
        }
        state = .loaded(AggregatedSearchResults.interleaving(answered))
    }

}
