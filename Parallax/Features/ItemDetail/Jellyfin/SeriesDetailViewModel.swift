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
    private(set) var isFavorite = false
    private(set) var resumeEpisode: Episode?

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
            isFavorite = sd.series.userData.isFavorite
            resumeEpisode = try? await repo.resumeEpisode(forSeries: itemID)
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

    func toggleFavorite() async {
        let target = !isFavorite
        isFavorite = target
        do { try await repo.setFavorite(itemID: itemID, isFavorite: target) }
        catch { isFavorite = !target; Log.ui.error("series toggleFavorite failed: \(String(describing: type(of: error)))") }
    }

    /// Mark the currently-selected season played (Jellyfin cascades to its episodes).
    func markSelectedSeasonWatched() async {
        guard let seasonID = selectedSeasonID else { return }
        do { try await repo.setPlayed(itemID: seasonID, isPlayed: true) }
        catch { Log.ui.error("markSeasonWatched failed: \(String(describing: type(of: error)))") }
    }

    func selectSeason(_ id: ItemID) async {
        selectedSeasonID = id
        episodesLoading = true
        do {
            let result = try await repo.episodes(of: id)
            // Drop a stale response: the user moved to another season (or the
            // auto-select raced a tap) while this fetch was in flight, so a
            // slower earlier fetch must not overwrite the newer season's list.
            guard selectedSeasonID == id else { return }
            episodes = result
        } catch {
            Log.ui.error("Season episodes load failed: \(String(describing: type(of: error)))")
            guard selectedSeasonID == id else { return }
            episodes = []
        }
        if selectedSeasonID == id { episodesLoading = false }
    }
}
