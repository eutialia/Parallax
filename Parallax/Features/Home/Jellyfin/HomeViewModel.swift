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
    /// True while `refresh()` re-pulls the progress-driven shelves in the background.
    /// The view dims + crossfades them (the library grid's stale-while-revalidate recipe)
    /// instead of dropping back to a skeleton.
    private(set) var isRefreshing = false
    private(set) var favoriteErrorMessage: String?

    /// Drives the favorite-failure alert. The view binds `$vm.isShowingFavoriteError`;
    /// dismissing it (set to false) clears the message — no inline `Binding(get:set:)` in the view.
    var isShowingFavoriteError: Bool {
        get { favoriteErrorMessage != nil }
        set { if !newValue { favoriteErrorMessage = nil } }
    }

    /// Showing the blocking full-screen failure with no content — the state an offline→online
    /// recovery should re-`load()`. Drives `.recoversFromOffline`.
    var isStalled: Bool { if case .failed = state { true } else { false } }

    private let repo: LibraryRepository
    private let userDataActions: UserDataActions
    private var changesTask: Task<Void, Never>?

    init(repo: LibraryRepository, userDataActions: UserDataActions) {
        self.repo = repo
        self.userDataActions = userDataActions
        // Own the iterating Task; cancelled in `isolated deinit` (needed to touch this
        // MainActor-isolated property). Self-notification is expected — this VM's own
        // toggleFavorite also lands here, re-applying the same server data it already set
        // (idempotent).
        changesTask = userDataActions.subscribe { [weak self] change in
            await self?.apply(change)
        }
    }

    isolated deinit {
        changesTask?.cancel()
    }

    /// React to a user-data change from any surface: patch this item wherever it lives (hero,
    /// Continue Watching, Next Up — `mutate` itself no-ops when Home holds none of them), then
    /// — for ANY played-operation change, regardless of whether Home currently holds the
    /// changed item — re-pull the two progress-driven shelves. Played state changes their
    /// membership (a newly-watched item leaves Continue Watching), and a series-level cascade
    /// can move episodes that back a Continue Watching/Next Up entry without the series itself
    /// ever appearing in Home's local state, so the refresh can't be gated on a local match.
    /// A pure favorite change never refetches.
    private func apply(_ change: UserDataActions.Change) async {
        mutate(change.itemID) { $0.withUserData(change.userData) }
        if change.operation == .played {
            await refresh()
        }
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

    /// Re-pull ONLY the progress-driven shelves (Continue Watching + Next Up) without a
    /// full reload — playback moves progress (incl. the new prev/next episode jumps), so
    /// landing back on Home should reflect it. The hero and the current shelves stay on
    /// screen (dimmed) through the round-trip, then the fresh lists crossfade in.
    /// No-op until the first `load()` has landed, and re-entrancy-guarded.
    func refresh() async {
        guard state == .loaded, !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            async let cwTask = repo.continueWatching()
            async let nuTask = repo.nextUp()
            let (cw, nu) = try await (cwTask, nuTask)
            try Task.checkCancellation()
            continueWatching = cw
            nextUp = nu
        } catch is CancellationError {
            return
        } catch let error as AppError {
            if case .network(let urlError) = error, urlError.code == .cancelled { return }
            // Non-fatal: keep the stale shelves rather than blanking a working screen.
            Log.ui.error("HomeViewModel refresh failed: \(error.userMessage) (\(error.networkDiagnostic))")
        } catch {
            Log.ui.error("HomeViewModel refresh unexpected: \(String(describing: type(of: error)))")
        }
    }

    func toggleFavorite(for itemID: ItemID) async {
        guard let original = currentItem(itemID)?.userData.isFavorite else { return }

        mutate(itemID) { $0.withFavorite(!original) }     // optimistic
        favoriteErrorMessage = nil

        switch await userDataActions.toggleFavorite(itemID: itemID, currentlyFavorite: original, via: repo) {
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
    /// (or the server's `UserItemData`) is swapped. Skips all three rebuilds outright when
    /// Home doesn't currently hold `itemID` anywhere.
    private func mutate(_ itemID: ItemID, _ transform: (Item) -> Item) {
        guard currentItem(itemID) != nil else { return }
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