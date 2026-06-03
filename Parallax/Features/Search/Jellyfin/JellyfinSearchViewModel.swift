import Foundation
import Observation
import os
import ParallaxCore
import ParallaxJellyfin

@Observable
@MainActor
final class JellyfinSearchViewModel {
    enum LoadState: Equatable {
        case idle, loading, loaded(SearchResults), failed(String)
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
    private let repo: LibraryRepository
    private let debouncer: AsyncDebouncer<String>
    private var consumerTask: Task<Void, Never>?

    init(repo: LibraryRepository) {
        self.repo = repo
        self.debouncer = AsyncDebouncer<String>(delay: .milliseconds(350))
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
    }

    private func runQuery(_ q: String) async {
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
        defer { isSearching = false }
        do {
            let results = try await repo.search(trimmed, scope: scope)
            state = .loaded(results)
        } catch let error as AppError {
            Log.ui.error("JellyfinSearch failed: \(error.userMessage)")
            state = .failed(error.userMessage)
        } catch {
            Log.ui.error("JellyfinSearch unexpected: \(String(describing: type(of: error)))")
            state = .failed("Something went wrong.")
        }
    }

}
