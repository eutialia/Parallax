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
    private let repo: LibraryRepository
    private let debouncer: AsyncDebouncer<String>
    private var consumerTask: Task<Void, Never>?

    init(repo: LibraryRepository) {
        self.repo = repo
        self.debouncer = AsyncDebouncer<String>(delay: .milliseconds(350))
    }

    func start() {
        guard consumerTask == nil else { return }
        consumerTask = Task { [weak self] in
            guard let self else { return }
            for await q in self.debouncer.stream {
                await self.runQuery(q)
            }
        }
    }

    func stop() {
        consumerTask?.cancel()
        consumerTask = nil
        Task { await debouncer.finish() }
    }

    private func runQuery(_ q: String) async {
        let trimmed = q.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            state = .idle
            return
        }
        state = .loading
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
