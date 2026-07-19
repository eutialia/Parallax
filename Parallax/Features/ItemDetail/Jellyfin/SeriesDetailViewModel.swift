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
    private(set) var episodesBySeasonID: [ItemID: [Episode]] = [:]

    /// Showing the blocking full-screen failure — the state an offline→online recovery should
    /// re-`load()`. Drives `.recoversFromOffline`.
    var isStalled: Bool { if case .failed = state { true } else { false } }
    private(set) var episodesLoading = false
    private(set) var isFavorite = false
    private(set) var resumeEpisode: Episode?
    /// Drives the stale-while-revalidate dim during `refresh()` (re-pull after a
    /// playback session ends). Also a re-entrancy guard.
    private(set) var isRefreshing = false

    private let repo: LibraryRepository
    private let itemID: ItemID
    private let userDataActions: UserDataActions
    private var changesTask: Task<Void, Never>?

    init(repo: LibraryRepository, itemID: ItemID, userDataActions: UserDataActions) {
        self.repo = repo
        self.itemID = itemID
        self.userDataActions = userDataActions
        // Own the iterating Task; cancelled in deinit.
        changesTask = userDataActions.subscribe { [weak self] change in
            await self?.apply(change)
        }
    }

    isolated deinit {
        changesTask?.cancel()
    }

    /// React to a user-data change from any surface. A change on THIS series patches the
    /// loaded detail and, when it's a played change, refetches the episode shelves + resume
    /// target — series cascade contract: marking a series played moves every episode
    /// server-side but the event still carries only the series' own itemID/UserItemData (no
    /// per-episode fan-out), so refetching is the only way to learn which episodes moved.
    /// Keying on `operation == .played` (rather than diffing a locally-cached flag) skips a
    /// needless re-pull on a pure favorite toggle. A played change for one of THIS series'
    /// OWN episodes (matched against `episodesBySeasonID` — this VM holds that list) patches
    /// the episode in place for the immediate badge, then ALSO refetches: marking an episode
    /// watched from its own shelf can move `resumeEpisode` to a different episode (or clear
    /// it), and the event carries only that one episode's data, never the new Next Up target.
    /// A favorite change on one of our episodes, or any change for an episode of a DIFFERENT
    /// series, stays a plain in-place patch (or no-op, if the itemID matches nothing we hold).
    /// Every patch below goes through `change.merged(into:)`, not the raw payload: a
    /// played-operation response's favorite field (or a favorite response's played/position
    /// fields) is a DTO-boundary default, not real state, and adopting it wholesale would flip
    /// the field the OTHER operation owns. Stays on `.loaded` throughout — `refresh()` already
    /// never re-skeletons.
    private func apply(_ change: UserDataActions.Change) async {
        guard case .loaded(let detail, let seasons) = state else { return }

        if detail.series.id == change.itemID {
            let merged = change.merged(into: detail.series.userData)
            state = .loaded(detail.withSeries(detail.series.withUserData(merged)), seasons)
            isFavorite = merged.isFavorite
            if change.operation == .played {
                await refresh()
            }
            return
        }

        if let resumeEpisode, resumeEpisode.id == change.itemID {
            self.resumeEpisode = resumeEpisode.withUserData(change.merged(into: resumeEpisode.userData))
        }
        for (seasonID, episodes) in episodesBySeasonID {
            guard let idx = episodes.firstIndex(where: { $0.id == change.itemID }) else { continue }
            episodesBySeasonID[seasonID]?[idx] = episodes[idx].withUserData(change.merged(into: episodes[idx].userData))
            if change.operation == .played {
                await refresh()
            }
            return
        }
    }

    func load() async {
        state = .loading
        do {
            async let detailTask = repo.detail(for: itemID)
            async let seasonsTask = repo.seasons(of: itemID)
            // Resume runs in parallel from the top — it's an independent /Shows/NextUp
            // call, so it must NOT serialize ahead of the episode-list fetch below
            // (that delayed the episodes by a full extra round-trip).
            async let resumeTask = repo.resumeEpisode(forSeries: itemID)
            let (detail, seasons) = try await (detailTask, seasonsTask)
            guard case .series(let sd) = detail else {
                state = .failed("Your server returned something that isn't a series.")
                return
            }
            state = .loaded(sd, seasons)
            isFavorite = sd.series.userData.isFavorite
            if !seasons.isEmpty {
                await loadEpisodes(for: seasons)
            }
            // resumeTask already ran concurrently; awaiting it here adds no latency.
            resumeEpisode = try? await resumeTask
        } catch let error as AppError {
            Log.ui.error("SeriesDetail load failed: \(error.userMessage)")
            state = .failed(error.userMessage)
        } catch {
            Log.ui.error("SeriesDetail load unexpected: \(String(describing: type(of: error)))")
            state = .failed("Something went wrong. Go back and open it again.")
        }
    }

    /// Re-pull the progress-driven data after a playback session ends so the season
    /// shelves' progress bars / watched checks and the hero's Resume target reflect the
    /// position the player just moved. Stays on `.loaded` and — crucially — does NOT set
    /// `episodesLoading`, so the shelves never flash their skeleton; the `staleWhileRevalidate`
    /// dim covers the swap instead. Both fields land in one `@Observable` transaction (no
    /// `await` between the assignments and the `defer`'d flag clear) so the dim lifts on fully
    /// fresh data. Re-fetch failure is non-fatal: keep the stale shelves, log.
    ///
    /// Only the episode-level state moves when an episode finishes, so refresh re-pulls just
    /// the episodes and the next-up Resume target. The series detail (overview, seasons) and
    /// `isFavorite` are untouched by playback, so it skips the `detail` re-pull entirely —
    /// fewer round-trips, and no race against an in-flight favorite toggle.
    func refresh() async {
        guard case .loaded(_, let seasons) = state, !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        async let resumeTask = repo.resumeEpisode(forSeries: itemID)
        let refreshedEpisodes = await fetchEpisodes(for: seasons)
        let refreshedResume = try? await resumeTask
        episodesBySeasonID = refreshedEpisodes
        resumeEpisode = refreshedResume
    }

    func episodes(for seasonID: ItemID) -> [Episode] {
        episodesBySeasonID[seasonID] ?? []
    }

    /// First playable episode — S1 E1 in the common case, skipping Specials
    /// (season 0) whenever a regular season exists. This is the "Play" target
    /// that survives a fully-watched series: Jellyfin's /Shows/NextUp returns
    /// nothing once everything is played (and treats an empty series as
    /// watched), which used to take the Play button down with it.
    var firstEpisode: Episode? {
        guard case .loaded(_, let seasons) = state else { return nil }
        let ordered = seasons.sorted { ($0.indexNumber ?? Int.max) < ($1.indexNumber ?? Int.max) }
        let regular = ordered.filter { ($0.indexNumber ?? 0) > 0 }
        for season in (regular.isEmpty ? ordered : regular) {
            if let first = episodesBySeasonID[season.id]?.first { return first }
        }
        return nil
    }

    func toggleFavorite() async {
        let original = isFavorite
        isFavorite = !original
        switch await userDataActions.toggleFavorite(itemID: itemID, currentlyFavorite: original, via: repo) {
        case .success(let server):
            isFavorite = server.isFavorite
        case .skipped:
            isFavorite = original
        case .failure(let error):
            isFavorite = original
            Log.ui.error("series toggleFavorite failed: \(error.userMessage) (\(error.networkDiagnostic))")
        }
    }

    private func loadEpisodes(for seasons: [Season]) async {
        episodesLoading = true
        episodesBySeasonID = await fetchEpisodes(for: seasons)
        episodesLoading = false
    }

    /// Concurrently fetch every season's episodes, swallowing a per-season failure to an
    /// empty list. Pure fetch — no state side effects — so `load()` (with the
    /// `episodesLoading` skeleton) and `refresh()` (dimmed, no skeleton) share it.
    private func fetchEpisodes(for seasons: [Season]) async -> [ItemID: [Episode]] {
        var bySeason: [ItemID: [Episode]] = [:]
        await withTaskGroup(of: (ItemID, [Episode]).self) { group in
            for season in seasons {
                let seasonID = season.id
                group.addTask {
                    do {
                        let episodes = try await self.repo.episodes(of: seasonID)
                        return (seasonID, episodes)
                    } catch {
                        Log.ui.error("Season episodes load failed: \(String(describing: type(of: error)))")
                        return (seasonID, [])
                    }
                }
            }
            for await (seasonID, episodes) in group {
                bySeason[seasonID] = episodes
            }
        }
        return bySeason
    }
}

/// `SeriesDetail`'s fields are `let` (no package-side mutated-copy API — adding one is a
/// `ParallaxCore` change, out of this task's scope), so patching the `series` field alone still
/// needs a full-struct copy. Kept to this one call site rather than rolled ad hoc: every other
/// field is passed through UNCHANGED (never recomputed), so there's nothing for a future field
/// to silently drop.
private extension SeriesDetail {
    func withSeries(_ series: Series) -> SeriesDetail {
        SeriesDetail(series: series, tagline: tagline, studios: studios, people: people)
    }
}
