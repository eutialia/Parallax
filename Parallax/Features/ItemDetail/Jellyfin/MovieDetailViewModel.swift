import Foundation
import Observation
import os
import ParallaxCore
import ParallaxJellyfin

@Observable
@MainActor
final class MovieDetailViewModel {
    enum LoadState: Equatable {
        case idle, loading, loaded(MovieDetail), failed(String)
    }

    private(set) var state: LoadState = .idle
    private(set) var isFavorite = false
    private(set) var isPlayed = false
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
            guard case .movie(let md) = detail else {
                state = .failed("Unexpected item type for this screen.")
                return
            }
            state = .loaded(md)
            isFavorite = md.movie.userData.isFavorite
            isPlayed = md.movie.userData.played
        } catch let error as AppError {
            Log.ui.error("MovieDetail load failed: \(error.userMessage)")
            state = .failed(error.userMessage)
        } catch {
            Log.ui.error("MovieDetail load unexpected: \(String(describing: type(of: error)))")
            state = .failed("Something went wrong.")
        }
    }

    func toggleFavorite() async {
        let target = !isFavorite
        isFavorite = target
        do { try await repo.setFavorite(itemID: itemID, isFavorite: target) }
        catch { isFavorite = !target; Log.ui.error("toggleFavorite failed: \(String(describing: type(of: error)))") }
    }

    func togglePlayed() async {
        let target = !isPlayed
        isPlayed = target
        do { try await repo.setPlayed(itemID: itemID, isPlayed: target) }
        catch { isPlayed = !target; Log.ui.error("togglePlayed failed: \(String(describing: type(of: error)))") }
    }
}
