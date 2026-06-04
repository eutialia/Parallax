import Foundation
import Observation
import os
import ParallaxCore
import ParallaxJellyfin

@Observable
@MainActor
final class HomeViewModel {
    enum LoadState: Equatable {
        case idle, loading, loaded, failed(String)
    }

    private(set) var state: LoadState = .idle
    private(set) var recentlyAdded: [Item] = []
    private(set) var continueWatching: [Item] = []
    private(set) var nextUp: [Item] = []
    /// Next-up episode per series id for hero resume on newly-added series.
    private(set) var resumeEpisodeBySeriesID: [ItemID: Episode] = [:]
    private(set) var favoriteErrorMessage: String?

    /// Drives the favorite-failure alert. The view binds `$vm.isShowingFavoriteError`;
    /// dismissing it (set to false) clears the message — no inline `Binding(get:set:)` in the view.
    var isShowingFavoriteError: Bool {
        get { favoriteErrorMessage != nil }
        set { if !newValue { favoriteErrorMessage = nil } }
    }

    private let repo: LibraryRepository

    init(repo: LibraryRepository) {
        self.repo = repo
    }

    func load() async {
        state = .loading
        do {
            async let recentTask = repo.recentlyAdded(limit: 12)
            async let cwTask = repo.continueWatching()
            async let nuTask = repo.nextUp()
            let (recent, cw, nu) = try await (recentTask, cwTask, nuTask)
            let resume = await Self.loadResumeEpisodes(for: recent, repo: repo)
            // The resume-episode fetch awaits after the main load; bail if the view's
            // task was cancelled meanwhile so we don't flip a torn-down screen to `.loaded`.
            try Task.checkCancellation()
            self.resumeEpisodeBySeriesID = resume
            // Opinionated: only surface newly-added series we can actually press Play on.
            // A series with no next-up episode has no imported media yet (or is fully
            // watched), so drop it from the hero. Movies are always playable.
            self.recentlyAdded = recent.filter { item in
                guard case .series(let s) = item else { return true }
                return resume[s.id] != nil
            }
            self.continueWatching = cw
            self.nextUp = nu
            self.state = .loaded
        } catch is CancellationError {
            return
        } catch let error as AppError {
            if case .network(let urlError) = error, urlError.code == .cancelled {
                return
            }
            Log.ui.error("HomeViewModel load failed: \(error.userMessage) (\(error.networkDiagnostic))")
            state = .failed(error.userMessage)
        } catch {
            Log.ui.error("HomeViewModel load unexpected: \(String(describing: type(of: error)))")
            state = .failed("Something went wrong.")
        }
    }

    func resumeEpisode(for item: Item) -> Episode? {
        guard case .series(let s) = item else { return nil }
        return resumeEpisodeBySeriesID[s.id]
    }

    func toggleFavorite(for itemID: ItemID) async {
        guard let original = currentItem(itemID)?.userData.isFavorite else { return }

        mutate(itemID) { $0.withFavorite(!original) }     // optimistic
        favoriteErrorMessage = nil

        switch await FavoriteToggle.perform(itemID: itemID, currentlyFavorite: original, via: repo) {
        case .success(let serverUserData):
            mutate(itemID) { $0.withUserData(serverUserData) }
        case .skipped:
            mutate(itemID) { $0.withFavorite(original) }
        case .failure(let error):
            mutate(itemID) { $0.withFavorite(original) }
            favoriteErrorMessage = error.userMessage
            Log.ui.error("Home toggleFavorite failed: \(error.userMessage) (\(error.networkDiagnostic))")
        }
    }

    private func currentItem(_ itemID: ItemID) -> Item? {
        recentlyAdded.first { $0.id == itemID }
            ?? continueWatching.first { $0.id == itemID }
            ?? nextUp.first { $0.id == itemID }
    }

    /// Apply `transform` to the matching item wherever it lives (hero, continue-watching,
    /// next-up). It mutates the *current* element rather than re-applying a captured copy,
    /// so a reload that lands mid-toggle keeps its fresh metadata — only the favorite flag
    /// (or the server's `UserItemData`) is swapped.
    private func mutate(_ itemID: ItemID, _ transform: (Item) -> Item) {
        recentlyAdded = recentlyAdded.map { $0.id == itemID ? transform($0) : $0 }
        continueWatching = continueWatching.map { $0.id == itemID ? transform($0) : $0 }
        nextUp = nextUp.map { $0.id == itemID ? transform($0) : $0 }
    }

    /// Fetch the resume/next-up episode for every newly-added series concurrently — one
    /// `/Shows/NextUp` round-trip each, fanned out so the slowest single call (not their
    /// sum) gates Home. A missing episode for any series is fine (dropped); cancellation
    /// surfaces via `Task.checkCancellation()` in `load()`.
    private static func loadResumeEpisodes(for items: [Item], repo: LibraryRepository) async -> [ItemID: Episode] {
        let seriesIDs = items.compactMap { item -> ItemID? in
            guard case .series(let s) = item else { return nil }
            return s.id
        }
        guard !seriesIDs.isEmpty else { return [:] }

        return await withTaskGroup(of: (ItemID, Episode?).self) { group in
            for id in seriesIDs {
                group.addTask { (id, try? await repo.resumeEpisode(forSeries: id)) }
            }
            var out: [ItemID: Episode] = [:]
            for await (id, episode) in group where episode != nil {
                out[id] = episode
            }
            return out
        }
    }
}
