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
    private(set) var heroFeed: [HomeHeroFeedEntry] = []
    private(set) var continueWatching: [Item] = []
    private(set) var nextUp: [Item] = []
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
            async let heroTask = repo.homeHeroFeed(limit: 12)
            async let cwTask = repo.continueWatching()
            async let nuTask = repo.nextUp()
            let (hero, cw, nu) = try await (heroTask, cwTask, nuTask)
            try Task.checkCancellation()
            self.heroFeed = hero
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
        for entry in heroFeed {
            if entry.presentation.id == itemID { return entry.presentation }
            if entry.playTarget.id == itemID { return entry.playTarget }
        }
        return continueWatching.first { $0.id == itemID }
            ?? nextUp.first { $0.id == itemID }
    }

    /// Apply `transform` to the matching item wherever it lives (hero, continue-watching,
    /// next-up). It mutates the *current* element rather than re-applying a captured copy,
    /// so a reload that lands mid-toggle keeps its fresh metadata — only the favorite flag
    /// (or the server's `UserItemData`) is swapped.
    private func mutate(_ itemID: ItemID, _ transform: (Item) -> Item) {
        heroFeed = heroFeed.map { entry in
            let presentation = entry.presentation.id == itemID ? transform(entry.presentation) : entry.presentation
            let playTarget = entry.playTarget.id == itemID ? transform(entry.playTarget) : entry.playTarget
            guard presentation != entry.presentation || playTarget != entry.playTarget else { return entry }
            return HomeHeroFeedEntry(presentation: presentation, playTarget: playTarget, eyebrow: entry.eyebrow)
        }
        continueWatching = continueWatching.map { $0.id == itemID ? transform($0) : $0 }
        nextUp = nextUp.map { $0.id == itemID ? transform($0) : $0 }
    }
}