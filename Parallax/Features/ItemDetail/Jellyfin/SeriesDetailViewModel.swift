import Foundation
import Observation
import os
import ParallaxCore
import ParallaxJellyfin

@Observable
@MainActor
final class SeriesDetailViewModel {
    enum LoadState: Equatable {
        case idle, loading, loaded(SeriesDetail, [Season]), failed(String)
    }

    private(set) var state: LoadState = .idle
    private(set) var selectedSeasonID: ItemID?
    private(set) var episodes: [Episode] = []
    private(set) var episodesLoading = false

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
            async let seasonsTask = repo.seasons(of: itemID)
            let (detail, seasons) = try await (detailTask, seasonsTask)
            guard case .series(let sd) = detail else {
                state = .failed("Unexpected item type for this screen.")
                return
            }
            state = .loaded(sd, seasons)
            if let first = seasons.first {
                await selectSeason(first.id)
            }
        } catch let error as AppError {
            Log.ui.error("SeriesDetail load failed: \(error.userMessage)")
            state = .failed(error.userMessage)
        } catch {
            Log.ui.error("SeriesDetail load unexpected: \(String(describing: type(of: error)))")
            state = .failed("Something went wrong.")
        }
    }

    func selectSeason(_ id: ItemID) async {
        selectedSeasonID = id
        episodesLoading = true
        defer { episodesLoading = false }
        do {
            episodes = try await repo.episodes(of: id)
        } catch {
            Log.ui.error("Season episodes load failed: \(String(describing: type(of: error)))")
            episodes = []
        }
    }
}
