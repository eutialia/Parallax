import Foundation
import Observation
import os
import ParallaxCore
import ParallaxJellyfin

@Observable
@MainActor
final class LibraryListViewModel {
    enum LoadState: Equatable {
        case idle, loading, loaded, failed(String)
    }

    private(set) var state: LoadState = .idle
    private(set) var collections: [MediaCollection] = []

    private let repo: any MediaRepository
    /// Library collection IDs hidden via the server's "Visible Libraries" screen — filtered out of
    /// `collections` so the iPhone library list matches the iPad sidebar / tvOS column.
    var hiddenCollectionIDs: Set<String>

    init(repo: any MediaRepository, hiddenCollectionIDs: Set<String> = []) {
        self.repo = repo
        self.hiddenCollectionIDs = hiddenCollectionIDs
    }

    func load() async {
        state = .loading
        do {
            let all = try await repo.collections()
            collections = all.filter { !hiddenCollectionIDs.contains($0.id.rawValue) }
            state = .loaded
        } catch let error as AppError {
            Log.ui.error("LibraryList load failed: \(error.userMessage)")
            state = .failed(error.userMessage)
        } catch {
            Log.ui.error("LibraryList load unexpected: \(String(describing: type(of: error)))")
            state = .failed("Something went wrong.")
        }
    }
}
