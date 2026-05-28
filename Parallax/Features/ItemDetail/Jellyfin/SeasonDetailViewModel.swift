import Foundation
import Observation
import os
import ParallaxCore
import ParallaxJellyfin

@Observable
@MainActor
final class SeasonDetailViewModel {
    enum LoadState: Equatable {
        case idle, loading, loaded(SeasonDetail, [Episode]), failed(String)
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
            async let detailTask = repo.detail(for: itemID)
            async let episodesTask = repo.episodes(of: itemID)
            let (detail, episodes) = try await (detailTask, episodesTask)
            guard case .season(let sd) = detail else {
                state = .failed("Unexpected item type for this screen.")
                return
            }
            state = .loaded(sd, episodes)
        } catch let error as AppError {
            Log.ui.error("SeasonDetail load failed: \(error.userMessage)")
            state = .failed(error.userMessage)
        } catch {
            Log.ui.error("SeasonDetail load unexpected: \(String(describing: type(of: error)))")
            state = .failed("Something went wrong.")
        }
    }
}
