import Foundation
import Observation
import os
import ParallaxCore
import ParallaxJellyfin

@Observable
@MainActor
final class LibraryGridViewModel {
    enum LoadState: Equatable {
        case idle, loading, loaded, failed(String)
    }

    private struct ReloadSnapshot {
        let items: [Item]
        let cursor: PageCursor?
        let state: LoadState
    }

    private(set) var state: LoadState = .idle
    private(set) var items: [Item] = []
    private(set) var isLoadingMore: Bool = false
    /// True while a sort/filter change is in flight but stale items are still shown.
    private(set) var isRefreshing: Bool = false
    /// Bumped only after a successful reset fetch — drives grid crossfade without O(n) ID scans.
    private(set) var refreshGeneration: UInt = 0
    /// Non-blocking error when a sort/filter refresh fails but stale items remain visible.
    private(set) var refreshErrorMessage: String?
    private(set) var availableGenres: [String] = []
    /// True while the genre list is in flight on first load — drives the placeholder
    /// row so the grid below doesn't shift when genres arrive.
    private(set) var isLoadingGenres: Bool = false

    /// Showing the blocking full-screen failure with no items — the state an offline→online
    /// recovery should re-`load()`. The refresh-error *banner* (`refreshErrorMessage`, stale
    /// items still visible) is deliberately excluded: it keeps its manual "Try again".
    var isStalled: Bool { if case .failed = state, items.isEmpty { true } else { false } }

    var sort: ItemSort = .defaultForLibrary {
        didSet { if sort != oldValue { Task { await reload() } } }
    }
    var filter: ItemFilter = ItemFilter() {
        didSet { if filter != oldValue { Task { await reload() } } }
    }

    // Picker lenses over the value-type `sort`/`filter`, so the views bind straight to these
    // (`$vm.selectedGenre`, `$vm.sortField`, `$vm.sortDirection`) instead of hand-rolling
    // `Binding(get:set:)` per call site. Each setter writes back through `sort`/`filter`, so their
    // `didSet` reload still fires; each getter reads the stored value, so `@Observable` tracks it.
    var selectedGenre: String? {
        // One genre at a time — a title can carry several, so this is "show me everything tagged X",
        // not a mutually-exclusive bucket. nil clears the filter.
        get { filter.genres.first }
        set { filter.genres = newValue.map { [$0] } ?? [] }
    }
    var sortField: ItemSort.Field {
        get { sort.field }
        // Picking a field adopts its natural direction (dates newest-first,
        // titles A→Z) instead of inheriting the previous field's order — the
        // direction palette re-labels per field, so a carried-over direction
        // would silently flip meaning ("Newest" → "Z to A").
        set { sort = ItemSort(field: newValue, direction: newValue.naturalDirection) }
    }
    var sortDirection: ItemSort.Direction {
        get { sort.direction }
        set { sort = ItemSort(field: sort.field, direction: newValue) }
    }

    private var cursor: PageCursor?
    private var inFlight: Task<Void, Never>?
    private var genreTask: Task<Void, Never>?
    private var reloadSnapshot: ReloadSnapshot?
    /// Monotonic token so only the latest reset fetch may mutate refresh UI state.
    private var fetchGeneration: UInt = 0
    private let repo: any MediaRepository
    private let scope: LibraryScope
    private var changesTask: Task<Void, Never>?

    init(repo: any MediaRepository, scope: LibraryScope, userDataActions: UserDataActions) {
        self.repo = repo
        self.scope = scope
        // Own the iterating Task; cancelled below alongside the grid's other in-flight work.
        changesTask = userDataActions.subscribe { [weak self] change in
            self?.apply(change)
        }
    }

    isolated deinit {
        // Close any live source connection (SMB opens a share socket on first `items()`;
        // Jellyfin's teardown is a no-op) when the grid is torn down. The capture keeps the
        // repo alive until the disconnect completes, after the view model is released.
        inFlight?.cancel()
        genreTask?.cancel()
        changesTask?.cancel()
        Task { [repo] in await repo.teardown() }
    }

    /// React to a user-data change from any surface. A Favorites-scope grid drops an item
    /// outright once `change.unfavorited` reports it's no longer a favorite (plain removal, no
    /// extra animation — it just no longer belongs). `unfavorited` itself is gated on
    /// `operation == .favorite`: a played-operation `UserItemData` can omit the favorite field
    /// entirely, which `UserItemDataDto.toUserItemData()` maps absent→false, so without that
    /// gate marking a favorited item watched would read as "unfavorited" and wrongly vanish it
    /// from Favorites. Every other change (including a played change here) patches the matching
    /// item's `userData` in place via `change.merged(into:)` — not the raw payload, for the
    /// same absent-field reason: adopting it wholesale would flip the field the OTHER operation
    /// owns to its DTO default. That in-place patch updates the watched badge / favorite-derived
    /// UI automatically since `MediaThumbnail` reads the item. Either way `state` stays `.loaded`
    /// — no re-skeleton. Early-outs when the grid doesn't hold `itemID` at all, skipping the
    /// array rebuild.
    private func apply(_ change: UserDataActions.Change) {
        if case .favorites = scope, change.unfavorited {
            items.removeAll { $0.id == change.itemID }
            return
        }
        guard let index = items.firstIndex(where: { $0.id == change.itemID }) else { return }
        items[index] = items[index].withUserData(change.merged(into: items[index].userData))
    }

    func load() async {
        guard state != .loading else { return }
        refreshErrorMessage = nil
        reloadSnapshot = nil
        state = .loading
        let generation = beginResetFetch()
        loadGenres()
        await fetchPage(reset: true, generation: generation)
    }

    func retryRefresh() async {
        guard refreshErrorMessage != nil else { return }
        await reload()
    }

    private func loadGenres() {
        genreTask?.cancel()
        isLoadingGenres = true
        genreTask = Task {
            let genres = (try? await repo.genres(in: scope)) ?? []
            guard !Task.isCancelled else { return }
            availableGenres = genres
            isLoadingGenres = false
        }
    }

    func loadMore() async {
        guard !isLoadingMore, !isRefreshing, cursor != nil, state == .loaded else { return }
        isLoadingMore = true
        await fetchPage(reset: false)
        isLoadingMore = false
    }

    private func reload() async {
        // Drive fetchPage directly rather than going through load(): a
        // sort/filter change can land while the first load is still in
        // flight (state == .loading). load()'s `guard state != .loading`
        // would then bail, leaving the grid stuck on the spinner forever.
        // We've already cancelled the in-flight task, so a fresh fetch is safe.
        inFlight?.cancel()
        refreshErrorMessage = nil
        let generation = beginResetFetch()

        if items.isEmpty {
            reloadSnapshot = nil
            state = .loading
        } else {
            reloadSnapshot = ReloadSnapshot(items: items, cursor: cursor, state: state)
            isRefreshing = true
        }
        cursor = nil
        await fetchPage(reset: true, generation: generation)
    }

    private func beginResetFetch() -> UInt {
        fetchGeneration &+= 1
        return fetchGeneration
    }

    private func restoreSnapshotIfNeeded() {
        guard let snapshot = reloadSnapshot else { return }
        items = snapshot.items
        cursor = snapshot.cursor
        state = snapshot.state
        reloadSnapshot = nil
    }

    private func isCurrentResetFetch(_ generation: UInt) -> Bool {
        generation == fetchGeneration
    }

    private func fetchPage(reset: Bool, generation: UInt? = nil) async {
        let snapshotSort = sort
        let snapshotFilter = filter
        let snapshotCursor = cursor
        inFlight = Task {
            do {
                let page = try await repo.items(
                    in: scope,
                    filter: snapshotFilter,
                    sort: snapshotSort,
                    cursor: snapshotCursor
                )
                guard !Task.isCancelled else { return }
                if let generation, !isCurrentResetFetch(generation) { return }

                if reset {
                    items = page.items
                    refreshGeneration &+= 1
                    reloadSnapshot = nil
                } else {
                    items.append(contentsOf: page.items)
                }
                cursor = page.nextCursor
                state = .loaded
                isRefreshing = false
                refreshErrorMessage = nil
            } catch let error as AppError {
                if !Task.isCancelled {
                    handleFetchFailure(error.userMessage, reset: reset, generation: generation)
                }
            } catch is CancellationError {
                if let generation, isCurrentResetFetch(generation) {
                    restoreSnapshotIfNeeded()
                    isRefreshing = false
                }
            } catch {
                if !Task.isCancelled {
                    Log.ui.error("LibraryGrid load unexpected: \(String(describing: type(of: error)))")
                    handleFetchFailure("Something went wrong.", reset: reset, generation: generation)
                }
            }
        }
        await inFlight?.value
    }

    private func handleFetchFailure(_ message: String, reset: Bool, generation: UInt?) {
        if let generation, !isCurrentResetFetch(generation) { return }

        Log.ui.error("LibraryGrid load failed: \(message)")
        isRefreshing = false

        if reset {
            restoreSnapshotIfNeeded()
            if items.isEmpty {
                state = .failed(message)
            } else {
                refreshErrorMessage = message
            }
        } else if items.isEmpty {
            state = .failed(message)
        }
    }
}