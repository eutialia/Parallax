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

    /// One Jellyfin server's feed surface, paired with the source tag its items get. The view model
    /// holds several of these rather than a single repo: Home aggregates every signed-in server.
    struct Feed: Sendable {
        let source: LibrarySource
        let repo: LibraryRepository

        init(session: Session, repo: LibraryRepository) {
            self.source = .jellyfin(session)
            self.repo = repo
        }

        /// One feed per signed-in Jellyfin server, in the store's order. Shared by both navigation
        /// roots (iOS `HomeView` self-loads; tvOS `FocusRootView` preloads behind the launch gate)
        /// so the two can't drift on which servers Home aggregates. Repos are built concurrently —
        /// the factory hops an actor per session.
        static func all(
            for sessions: [Session],
            repoFactory: @Sendable @escaping (Session) async -> LibraryRepository
        ) async -> [Feed] {
            // Only the repo build runs off-actor; the `Feed` itself is assembled back here.
            // `Feed.init` is MainActor-isolated (nested in a `@MainActor` type), so constructing it
            // inside the child task is an isolation violation the compiler already warns about.
            await withTaskGroup(of: (Int, Session, LibraryRepository).self) { group in
                for (index, session) in sessions.enumerated() {
                    group.addTask { (index, session, await repoFactory(session)) }
                }
                var out: [(Int, Session, LibraryRepository)] = []
                for await result in group { out.append(result) }
                return out.sorted { $0.0 < $1.0 }.map { Feed(session: $0.1, repo: $0.2) }
            }
        }
    }

    private(set) var state: LoadState = .idle
    private(set) var heroFeed: [SourcedHeroEntry] = []
    private(set) var continueWatching: [SourcedItem] = []
    private(set) var nextUp: [SourcedItem] = []
    /// True while `refresh()` re-pulls the progress-driven shelves in the background.
    /// The view dims + crossfades them (the library grid's stale-while-revalidate recipe)
    /// instead of dropping back to a skeleton.
    private(set) var isRefreshing = false
    /// Set when `refresh()` is called while one is already in flight. The in-flight run may
    /// have started before the change that requested this call, so rather than dropping the
    /// request, `refresh()` re-runs itself once more after the current pass completes.
    private var refreshQueued = false
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

    /// Servers whose slice failed the last `load()` while at least one other server answered.
    /// Home stays `.loaded` in that case (one dead server must not blank a working screen), so
    /// `isStalled` is false and nothing would ever re-pull them — the sidebar repairs itself per
    /// source, and Home has to as well or a server that was down at launch stays missing from the
    /// shelves until the app is relaunched.
    private(set) var failedSourceIDs: Set<MediaSourceID> = []

    /// Whether an offline→online recovery has anything to do: the whole screen failed, or some
    /// servers did. Drives `.recoversFromOffline`; the view picks `load()` vs `reloadFailedFeeds()`.
    var needsOfflineRepair: Bool { isStalled || !failedSourceIDs.isEmpty }

    private let feeds: [Feed]
    private let userDataActions: UserDataActions
    private var changesTask: Task<Void, Never>?

    /// The servers this model aggregates, in order. `feeds` is fixed at init, so a change here
    /// means the model is answering for the wrong set of servers and must be rebuilt — the view
    /// compares against it rather than assuming one model lasts the whole session (adding a
    /// second server left the first model in place, so Home stayed single-server until relaunch).
    var sourceIDs: [MediaSourceID] { feeds.map(\.source.sourceID) }

    init(feeds: [Feed], userDataActions: UserDataActions) {
        self.feeds = feeds
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
        mutate(change.itemID, source: change.source) { $0.withUserData(change.merged(into: $0.userData)) }
        if change.operation == .played {
            await refresh()
        }
    }

    func load() async {
        state = .loading
        // Every server's three feeds, fanned out concurrently and merged. Each server's slice
        // fails INDEPENDENTLY: a dead or slow server contributes empty lists instead of taking the
        // whole screen down with it, which is the difference between "one of my servers is
        // unreachable" and "Home is broken". `state` only goes `.failed` when EVERY server failed.
        let results = await withTaskGroup(of: (Int, FeedSlice?).self) { group in
            for (index, feed) in feeds.enumerated() {
                group.addTask { (index, await Self.loadSlice(feed)) }
            }
            var out: [(Int, FeedSlice?)] = []
            for await result in group { out.append(result) }
            return out.sorted { $0.0 < $1.0 }.map(\.1)
        }

        // Cancellation is NOT a server failure. `loadSlice` catches every error, so a cancelled
        // load (the enclosing `.task(id:)` re-firing) arrives here as "every server threw" and
        // would otherwise commit `.failed` — a permanent "couldn't reach your servers" whenever
        // the reload token moves mid-load without the server set changing (a Visible Libraries
        // edit). Back out to `.idle` instead; the view re-runs `load()` for an unsettled model.
        guard !Task.isCancelled else {
            state = .idle
            return
        }

        let slices = results.compactMap { $0 }
        guard !slices.isEmpty else {
            // Nothing came back at all. With no configured feeds that's an empty Home, not a
            // failure; with feeds present it means every one of them threw.
            failedSourceIDs = Set(feeds.map(\.source.sourceID))
            state = feeds.isEmpty ? .loaded : .failed("Parallax couldn't reach your servers.")
            return
        }
        commit(slices)
        failedSourceIDs = Set(zip(feeds, results).compactMap { $1 == nil ? $0.source.sourceID : nil })
        if slices.count < feeds.count {
            Log.ui.error("Home: \(self.feeds.count - slices.count) of \(self.feeds.count) server(s) failed; showing the rest")
        }
        state = .loaded
    }

    /// Re-pull ONLY the servers that failed the last `load()`, keeping everything already on
    /// screen. Drives `.recoversFromOffline` for the PARTIAL-failure case, which `load()` can't
    /// serve: it would drop back to `.loading` and flash the skeleton over content that never
    /// stopped working. Mirrors `FavoritesViewModel.reloadFailedSections`.
    func reloadFailedFeeds() async {
        let failed = feeds.filter { failedSourceIDs.contains($0.source.sourceID) }
        guard !failed.isEmpty else { return }
        let repaired = await withTaskGroup(of: (MediaSourceID, FeedSlice?).self) { group in
            for feed in failed {
                // Resolved out here: `sourceID` is a synchronous MainActor-isolated read, so
                // touching it inside the child task is an isolation violation.
                let id = feed.source.sourceID
                group.addTask { (id, await Self.loadSlice(feed)) }
            }
            var out: [MediaSourceID: FeedSlice] = [:]
            for await (id, slice) in group {
                if let slice { out[id] = slice }
            }
            return out
        }
        guard !Task.isCancelled, !repaired.isEmpty else { return }
        // Re-merge in feed order: the repaired slice for a server that came back, what's already
        // on screen for the ones that were fine, nothing for a server still unreachable.
        var merged: [FeedSlice] = []
        for feed in feeds {
            let id = feed.source.sourceID
            if let slice = repaired[id] {
                merged.append(slice)
                failedSourceIDs.remove(id)
            } else if !failedSourceIDs.contains(id) {
                merged.append(onScreenSlice(for: id))
            }
        }
        commit(merged)
    }

    /// What this server currently contributes to the shelves — used to carry a healthy server's
    /// items across a merge that only re-fetched some servers.
    private func onScreenSlice(for source: MediaSourceID) -> FeedSlice {
        FeedSlice(
            hero: heroFeed.filter { $0.source.sourceID == source },
            continueWatching: continueWatching.filter { $0.source.sourceID == source },
            nextUp: nextUp.filter { $0.source.sourceID == source }
        )
    }

    /// Re-pull ONLY the progress-driven shelves (Continue Watching + Next Up) without a
    /// full reload — playback moves progress (incl. the new prev/next episode jumps), so
    /// landing back on Home should reflect it. The hero and the current shelves stay on
    /// screen (dimmed) through the round-trip, then the fresh lists crossfade in.
    /// No-op until the first `load()` has landed, and re-entrancy-guarded.
    func refresh() async {
        guard state == .loaded else { return }
        // A refresh requested while one is already in flight can't just drop through: the
        // in-flight fetch may have started before the change that requested THIS call, so it
        // can land already stale relative to it. Queue one trailing pass instead of dropping
        // it — `refreshQueued` is re-checked after every pass, so a queue raised during the
        // trailing pass itself queues exactly one more (never unbounded: each pass awaits
        // real network round-trips).
        guard !isRefreshing else {
            refreshQueued = true
            return
        }
        isRefreshing = true
        defer { isRefreshing = false }
        repeat {
            refreshQueued = false
            let results = await withTaskGroup(of: (Int, ProgressSlice?).self) { group in
                for (index, feed) in feeds.enumerated() {
                    group.addTask { (index, await Self.loadProgressSlice(feed)) }
                }
                var out: [(Int, ProgressSlice?)] = []
                for await result in group { out.append(result) }
                return out.sorted { $0.0 < $1.0 }.map(\.1)
            }
            if Task.isCancelled { return }
            let slices = results.compactMap { $0 }
            // Every server failed → keep the stale shelves rather than blanking a working screen.
            guard !slices.isEmpty || feeds.isEmpty else { continue }
            // PARTIAL failure carries the missing server's items forward instead of dropping them:
            // re-merging only the answered servers would silently delete a momentarily-unreachable
            // server's Continue Watching rows from a screen that is otherwise fine — the
            // single-server code this replaced kept its stale shelves for exactly that reason.
            var cw: [[SourcedItem]] = []
            var nu: [[SourcedItem]] = []
            for (feed, slice) in zip(feeds, results) {
                let id = feed.source.sourceID
                cw.append(slice?.continueWatching ?? continueWatching.filter { $0.source.sourceID == id })
                nu.append(slice?.nextUp ?? nextUp.filter { $0.source.sourceID == id })
            }
            continueWatching = .mergedByLastPlayed(cw)
            nextUp = .interleaved(nu)
        } while refreshQueued
    }

    func toggleFavorite(for itemID: ItemID, source: MediaSourceID) async {
        guard let current = currentItem(itemID, source: source),
              let repo = repo(for: source) else { return }
        let original = current.userData.isFavorite

        mutate(itemID, source: source) { $0.withFavorite(!original) }     // optimistic
        favoriteErrorMessage = nil

        switch await userDataActions.toggleFavorite(
            itemID: itemID,
            source: source,
            currentlyFavorite: original,
            via: repo
        ) {
        case .success(let serverUserData):
            // Merge-scoped like every other patch site: a favorite response's played/position
            // fields are DTO-boundary defaults, not real state — never adopt them wholesale.
            mutate(itemID, source: source) {
                $0.withUserData(UserDataActions.merge(.favorite, payload: serverUserData, into: $0.userData))
            }
        case .skipped:
            mutate(itemID, source: source) { $0.withFavorite(original) }
        case .failure(let error):
            mutate(itemID, source: source) { $0.withFavorite(original) }
            favoriteErrorMessage = error.userMessage
            Log.ui.error("Home toggleFavorite failed: \(error.userMessage) (\(error.networkDiagnostic))")
        }
    }

    // MARK: - Fan-out

    /// One server's full Home contribution.
    private struct FeedSlice {
        let hero: [SourcedHeroEntry]
        let continueWatching: [SourcedItem]
        let nextUp: [SourcedItem]
    }

    /// One server's progress-shelf contribution (the `refresh()` subset).
    private struct ProgressSlice {
        let continueWatching: [SourcedItem]
        let nextUp: [SourcedItem]
    }

    /// nil when this server's feed failed — the caller drops it and keeps the others.
    private static func loadSlice(_ feed: Feed) async -> FeedSlice? {
        do {
            async let heroTask = feed.repo.homeHeroFeed(limit: 12)
            async let cwTask = feed.repo.continueWatching()
            async let nuTask = feed.repo.nextUp()
            let (hero, cw, nu) = try await (heroTask, cwTask, nuTask)
            return FeedSlice(
                hero: hero.map { SourcedHeroEntry(entry: $0, source: feed.source) },
                continueWatching: cw.map { SourcedItem(item: $0, source: feed.source) },
                nextUp: nu.map { SourcedItem(item: $0, source: feed.source) }
            )
        } catch {
            Log.ui.error("Home feed failed for \(feed.source.displayName): \(error.networkDiagnostic)")
            return nil
        }
    }

    private static func loadProgressSlice(_ feed: Feed) async -> ProgressSlice? {
        do {
            async let cwTask = feed.repo.continueWatching()
            async let nuTask = feed.repo.nextUp()
            let (cw, nu) = try await (cwTask, nuTask)
            return ProgressSlice(
                continueWatching: cw.map { SourcedItem(item: $0, source: feed.source) },
                nextUp: nu.map { SourcedItem(item: $0, source: feed.source) }
            )
        } catch {
            Log.ui.error("Home refresh failed for \(feed.source.displayName): \(error.networkDiagnostic)")
            return nil
        }
    }

    private func commit(_ slices: [FeedSlice]) {
        // Continue Watching merges on `lastPlayedDate` — the one key both servers express — so the
        // shelf reads as a single timeline. Hero and Next Up have no comparable cross-server key
        // (hero is a curated recency mix, Next Up is server-ranked), so they interleave round-robin,
        // which keeps every server visible near the front instead of burying the second server
        // behind the whole of the first.
        continueWatching = .mergedByLastPlayed(slices.map(\.continueWatching))
        nextUp = .interleaved(slices.map(\.nextUp))
        heroFeed = .interleaved(slices.map(\.hero))
    }

    private func repo(for source: MediaSourceID) -> LibraryRepository? {
        feeds.first { $0.source.sourceID == source }?.repo
    }

    // MARK: - Local patching

    private func currentItem(_ itemID: ItemID, source: MediaSourceID) -> Item? {
        for entry in heroFeed where entry.source.sourceID == source {
            if entry.entry.presentation.id == itemID { return entry.entry.presentation }
            if entry.entry.playTarget.id == itemID { return entry.entry.playTarget }
        }
        return continueWatching.first { $0.item.id == itemID && $0.source.sourceID == source }?.item
            ?? nextUp.first { $0.item.id == itemID && $0.source.sourceID == source }?.item
    }

    /// Apply `transform` to the matching item wherever it lives (hero, continue-watching,
    /// next-up). It mutates the *current* element rather than re-applying a captured copy,
    /// so a reload that lands mid-toggle keeps its fresh metadata — only the favorite flag
    /// (or the server's `UserItemData`) is swapped. Skips all three rebuilds outright when
    /// Home doesn't currently hold `itemID` anywhere.
    ///
    /// Matches on (source, itemID), never `itemID` alone: Jellyfin derives item GUIDs
    /// deterministically from the media path, so two servers over the same library layout can mint
    /// the SAME id — and even without a collision, a favorite toggled on server A must not repaint
    /// a different server's tile.
    private func mutate(_ itemID: ItemID, source: MediaSourceID, _ transform: (Item) -> Item) {
        guard currentItem(itemID, source: source) != nil else { return }
        heroFeed = heroFeed.map { sourced in
            guard sourced.source.sourceID == source else { return sourced }
            let entry = sourced.entry
            let presentation = entry.presentation.id == itemID ? transform(entry.presentation) : entry.presentation
            let playTarget = entry.playTarget.id == itemID ? transform(entry.playTarget) : entry.playTarget
            guard presentation != entry.presentation || playTarget != entry.playTarget else { return sourced }
            return SourcedHeroEntry(
                entry: HomeHeroFeedEntry(presentation: presentation, playTarget: playTarget, eyebrow: entry.eyebrow),
                source: sourced.source
            )
        }
        continueWatching = continueWatching.map { patched($0, itemID: itemID, source: source, transform) }
        nextUp = nextUp.map { patched($0, itemID: itemID, source: source, transform) }
    }

    private func patched(
        _ sourced: SourcedItem,
        itemID: ItemID,
        source: MediaSourceID,
        _ transform: (Item) -> Item
    ) -> SourcedItem {
        guard sourced.item.id == itemID, sourced.source.sourceID == source else { return sourced }
        return SourcedItem(item: transform(sourced.item), source: sourced.source)
    }
}
