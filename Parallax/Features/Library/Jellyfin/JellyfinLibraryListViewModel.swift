import Foundation
import Observation
import os
import ParallaxCore
import ParallaxJellyfin

@Observable
@MainActor
final class JellyfinLibraryListViewModel {
    enum LoadState: Equatable {
        case idle, loading, loaded, failed(String)
    }

    private(set) var state: LoadState = .idle
    private(set) var collections: [MediaCollection] = []

    private let repo: LibraryRepository

    init(repo: LibraryRepository) {
        self.repo = repo
    }

    func load() async {
        state = .loading
        do {
            collections = try await repo.collections()
            state = .loaded
        } catch let error as AppError {
            Log.ui.error("JellyfinLibraryList load failed: \(error.userMessage)")
            state = .failed(error.userMessage)
        } catch {
            Log.ui.error("JellyfinLibraryList load unexpected: \(String(describing: type(of: error)))")
            state = .failed("Something went wrong.")
        }
    }
}
