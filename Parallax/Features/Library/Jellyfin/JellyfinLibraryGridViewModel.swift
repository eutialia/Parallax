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

    private(set) var state: LoadState = .idle
    private(set) var items: [Item] = []
    private(set) var isLoadingMore: Bool = false
    private(set) var availableGenres: [String] = []

    var sort: ItemSort = .defaultForLibrary {
        didSet { if sort != oldValue { Task { await reload() } } }
    }
    var filter: ItemFilter = ItemFilter() {
        didSet { if filter != oldValue { Task { await reload() } } }
    }

    private var cursor: PageCursor?
    private var inFlight: Task<Void, Never>?
    private let repo: LibraryRepository
    private let collectionID: CollectionID

    init(repo: LibraryRepository, collectionID: CollectionID) {
        self.repo = repo
        self.collectionID = collectionID
    }

    func load() async {
        guard state != .loading else { return }
        state = .loading
        await fetchPage(reset: true)
        availableGenres = (try? await repo.genres(in: collectionID)) ?? []
    }

    func loadMore() async {
        guard !isLoadingMore, cursor != nil, state == .loaded else { return }
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
        cursor = nil
        items = []
        state = .loading
        await fetchPage(reset: true)
    }

    private func fetchPage(reset: Bool) async {
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
                if reset {
                    self.items = page.items
                } else {
                    self.items.append(contentsOf: page.items)
                }
                self.cursor = page.nextCursor
                self.state = .loaded
            } catch let error as AppError {
                if !Task.isCancelled {
                    Log.ui.error("JellyfinLibraryGrid load failed: \(error.userMessage)")
                    self.state = .failed(error.userMessage)
                }
            } catch is CancellationError {
                // expected on sort/filter change; reload() takes over
            } catch {
                if !Task.isCancelled {
                    Log.ui.error("JellyfinLibraryGrid load unexpected: \(String(describing: type(of: error)))")
                    self.state = .failed("Something went wrong.")
                }
            }
        }
        await inFlight?.value
    }
}
