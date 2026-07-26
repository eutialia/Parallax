import Foundation
import Observation
import os
import ParallaxCore
import ParallaxJellyfin

@Observable
@MainActor
final class JellyfinSearchViewModel {
    enum LoadState: Equatable {
        case idle, loading, loaded(AggregatedSearchResults), failed(String)
    }

    var query: String = "" {
        didSet {
            if query != oldValue {
                Task { await debouncer.update(query) }
            }
        }
    }

    var scope: SearchScope = .all {
        didSet {
            if scope != oldValue {
                Task { await debouncer.update(query) }
            }
        }
    }

    private(set) var state: LoadState = .idle
    /// True while a refine query is in flight on top of existing results — drives an
    /// inline indicator instead of tearing the whole results page down.
    private(set) var isSearching = false

    /// Showing the blocking full-screen failure — the state an offline→online recovery should
    /// re-run the last query for. Drives `.recoversFromOffline`.
    var isStalled: Bool { if case .failed = state { true } else { false } }
    /// A search session is on screen (loading/loaded/failed) — false only at idle. Drives the
    /// scope row's visibility so it enters/leaves in the same motion as the content swap
    /// (both flip on the same debounced state transition, unlike the raw keystroke).
    var hasActiveSearch: Bool { state != .idle }
    /// Every searchable source. Sources that can't answer yet (SMB, until it has an index) report
    /// `canSearch == false` and are filtered out here, so they contribute nothing rather than
    /// erroring — see `SearchProviding`.
    private let providers: [any SearchProviding]
    private let debouncer: AsyncDebouncer<String>
    private var consumerTask: Task<Void, Never>?
    private var changesTask: Task<Void, Never>?
    /// Monotonic token so only the LATEST query may write results. The consumer loop serializes
    /// debounced queries, but `retry()` calls `runQuery` directly (offline recovery), so a recovery
    /// query can overlap an in-flight debounced one (MainActor is reentrant across `await search`).
    /// Last query wins — mirrors `LibraryGridViewModel`/`SMBBrowseViewModel`'s generation guard.
    private var queryGeneration = 0

    /// The sources this model searches, in order. `providers` is fixed at init, so a change here
    /// means the model is answering for the wrong set of servers and must be rebuilt — see
    /// `matches(_:)` (mirrors `HomeViewModel.sourceIDs`).
    var sourceIDs: [MediaSourceID] { providers.map(\.source.sourceID) }

    /// Whether this model already answers for exactly `candidates`. The `canSearch` filter is
    /// applied here rather than at the call site so the view's rebuild test can't drift from
    /// `init`'s filtering — otherwise a source that reports `canSearch == false` (SMB, until it
    /// has an index) would never compare equal and the model would be rebuilt on every token.
    func matches(_ candidates: [any SearchProviding]) -> Bool {
        sourceIDs == candidates.filter(\.canSearch).map(\.source.sourceID)
    }

    init(providers: [any SearchProviding], userDataActions: UserDataActions) {
        self.providers = providers.filter(\.canSearch)
        self.debouncer = AsyncDebouncer<String>(delay: .milliseconds(350))
        // Own the iterating Task; cancelled below alongside the search consumer loop.
        changesTask = userDataActions.subscribe { [weak self] change in
            self?.apply(change)
        }
    }

    func start() {
        guard consumerTask == nil else { return }
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
    func retry() async {
        await runQuery(query)
    }

    private func runQuery(_ q: String) async {
        queryGeneration += 1
        let generation = queryGeneration
        let trimmed = q.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            state = .idle
            isSearching = false
            return
        }
        // Full-page spinner only on the FIRST search. Once results are on screen, keep
        // them mounted while refining (so the ScrollView keeps its offset and the main
        // actor isn't busy rebuilding the whole grid on every keystroke) and show a
        // small inline indicator via `isSearching` instead.
        if case .loaded = state {} else { state = .loading }
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
                group.addTask {
                    do {
                        return (index, (provider.source, try await provider.search(trimmed, scope: currentScope)))
                    } catch {
                        Log.ui.error("Search failed for \(provider.source.displayName): \(error.networkDiagnostic)")
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
