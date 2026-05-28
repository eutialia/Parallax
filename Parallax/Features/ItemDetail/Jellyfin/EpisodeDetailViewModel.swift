import Foundation
import Observation
import os
import ParallaxCore
import ParallaxJellyfin

@Observable
@MainActor
final class EpisodeDetailViewModel {
    enum LoadState: Equatable {
        case idle, loading, loaded(EpisodeDetail), failed(String)
    }

    private(set) var state: LoadState = .idle
    private let repo: LibraryRepository
    private let itemID: ItemID

    init(repo: LibraryRepository, itemID: ItemID) {
        self.repo = repo
        self.itemID = itemID
    }

    func load() async {
        state = .loading
        do {
            let detail = try await repo.detail(for: itemID)
            guard case .episode(let ed) = detail else {
                state = .failed("Unexpected item type for this screen.")
                return
            }
            state = .loaded(ed)
        } catch let error as AppError {
            Log.ui.error("EpisodeDetail load failed: \(error.userMessage)")
            state = .failed(error.userMessage)
        } catch {
            Log.ui.error("EpisodeDetail load unexpected: \(String(describing: type(of: error)))")
            state = .failed("Something went wrong.")
        }
    }
}
