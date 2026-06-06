import Foundation
import Observation
import os
import ParallaxCore
import ParallaxJellyfin

@Observable
@MainActor
final class JellyfinLibraryGridViewModel {
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

    var sort: ItemSort = .defaultForLibrary {
        didSet { if sort != oldValue { Task { await reload() } } }
    }
    var filter: ItemFilter = ItemFilter() {
        didSet { if filter != oldValue { Task { await reload() } } }
    }

    private var cursor: PageCursor?
    private var inFlight: Task<Void, Never>?
    private var genreTask: Task<Void, Never>?
    private var reloadSnapshot: ReloadSnapshot?
    /// Monotonic token so only the latest reset fetch may mutate refresh UI state.
    private var fetchGeneration: UInt = 0
    private let repo: LibraryRepository
    private let collectionID: CollectionID

    init(repo: LibraryRepository, collectionID: CollectionID) {
        self.repo = repo
        self.collectionID = collectionID
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
            let genres = (try? await repo.genres(in: collectionID)) ?? []
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
                    in: collectionID,
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
                    Log.ui.error("JellyfinLibraryGrid load unexpected: \(String(describing: type(of: error)))")
                    handleFetchFailure("Something went wrong.", reset: reset, generation: generation)
                }
            }
        }
        await inFlight?.value
    }

    private func handleFetchFailure(_ message: String, reset: Bool, generation: UInt?) {
        if let generation, !isCurrentResetFetch(generation) { return }

        Log.ui.error("JellyfinLibraryGrid load failed: \(message)")
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