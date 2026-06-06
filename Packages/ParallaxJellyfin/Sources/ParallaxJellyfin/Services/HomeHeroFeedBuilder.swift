import Foundation

public enum HomeHeroFeedBuilder {
    public static let defaultImportWindow: TimeInterval = 24 * 60 * 60

    /// Episode rows from a bulk series import can dominate a combined Latest response.
    /// Fetch movies separately; over-fetch episodes so post-dedupe still fills the carousel.
    public static let episodeLatestFetchCap = 100

    public static func episodeLatestFetchLimit(presentationLimit: Int) -> Int {
        min(episodeLatestFetchCap, max(48, presentationLimit * 4))
    }

    /// Minimum episode rows in one Latest batch that signals a bulk series import.
    public static let bulkImportEpisodeThreshold = 3

    public static func build(
        latestItems: [Item],
        seriesByID: [String: Series],
        firstEpisodeBySeriesID: [String: Episode],
        limit: Int,
        continueWatching: [Item] = [],
        importWindow: TimeInterval = defaultImportWindow
    ) -> [HomeHeroFeedEntry] {
        var movies: [(item: Item, date: Date)] = []
        var episodesBySeries: [String: [Episode]] = [:]

        for item in latestItems {
            switch item {
            case .movie(let movie):
                if let date = movie.dateAdded {
                    movies.append((.movie(movie), date))
                }
            case .episode(let episode):
                episodesBySeries[episode.seriesID.rawValue, default: []].append(episode)
            case .series:
                break
            }
        }

        var entries: [(entry: HomeHeroFeedEntry, date: Date)] = []

        for (movie, date) in movies {
            entries.append((
                HomeHeroFeedEntry(presentation: movie, playTarget: movie, eyebrow: .newlyAdded),
                date
            ))
        }

        for (seriesID, episodes) in episodesBySeries.sorted(by: { $0.key < $1.key }) {
            guard let series = seriesByID[seriesID] else { continue }
            let presentation: Item = .series(series)
            let newest = episodes.max(by: { ($0.dateAdded ?? .distantPast) < ($1.dateAdded ?? .distantPast) })!
            let newestDate = newest.dateAdded ?? .distantPast
            let eyebrow = classifyEyebrow(
                seriesDate: series.dateAdded,
                episodes: episodes,
                window: importWindow
            )
            let playEpisode = resolvePlayEpisode(
                episodes: episodes,
                eyebrow: eyebrow,
                fallback: firstEpisodeBySeriesID[seriesID]
            )
            let playTarget: Item = .episode(playEpisode)
            entries.append((
                HomeHeroFeedEntry(presentation: presentation, playTarget: playTarget, eyebrow: eyebrow),
                newestDate
            ))
        }

        let cwContext = continueWatchingContext(from: continueWatching)
        return entries
            .filter { !shouldExcludeFromHero(entry: $0.entry, continueWatching: cwContext) }
            .sorted { $0.date > $1.date }
            .prefix(limit)
            .map(\.entry)
    }

    /// Shared with `LibraryRepository` for seriesNextUp fallback gating.
    public static func isNewlyAdded(
        seriesDate: Date?,
        episodes: [Episode],
        window: TimeInterval = defaultImportWindow
    ) -> Bool {
        classifyEyebrow(seriesDate: seriesDate, episodes: episodes, window: window) == .newlyAdded
    }

    private static func classifyEyebrow(
        seriesDate: Date?,
        episodes: [Episode],
        window: TimeInterval
    ) -> HeroEyebrow {
        let dates = episodes.compactMap(\.dateAdded)
        guard let newestDate = dates.max() else { return .newEpisodeAvailable }

        // One episode row and no series `dateCreated` — a drop on an existing show.
        if episodes.count == 1, seriesDate == nil {
            return .newEpisodeAvailable
        }

        // Bulk import: many episode rows landed together (full-series import).
        if episodes.count >= bulkImportEpisodeThreshold, let oldest = dates.min() {
            if abs(newestDate.timeIntervalSince(oldest)) <= window {
                return .newlyAdded
            }
        }

        let effectiveSeriesDate = seriesDate ?? dates.min()
        guard let effectiveSeriesDate else { return .newEpisodeAvailable }
        if abs(newestDate.timeIntervalSince(effectiveSeriesDate)) <= window {
            return .newlyAdded
        }
        return .newEpisodeAvailable
    }

    private static func resolvePlayEpisode(
        episodes: [Episode],
        eyebrow: HeroEyebrow,
        fallback: Episode?
    ) -> Episode {
        if eyebrow == .newlyAdded {
            if let first = episodes.min(by: compareEpisodeOrder) { return first }
            if let fallback { return fallback }
        }
        let newest = episodes.max(by: { ($0.dateAdded ?? .distantPast) < ($1.dateAdded ?? .distantPast) })!
        if newest.userData.playbackPositionTicks > 0 && !newest.userData.played {
            return newest
        }
        if eyebrow == .newEpisodeAvailable {
            return newest
        }
        return episodes.min(by: compareEpisodeOrder) ?? newest
    }

    private static func compareEpisodeOrder(_ a: Episode, _ b: Episode) -> Bool {
        let seasonA = a.parentIndexNumber ?? Int.max
        let seasonB = b.parentIndexNumber ?? Int.max
        if seasonA != seasonB { return seasonA < seasonB }
        return (a.indexNumber ?? Int.max) < (b.indexNumber ?? Int.max)
    }

    /// Movies always surface as `NEWLY ADDED`. Series suppress when that import is stale
    /// for the user (already in Continue Watching). `NEW EPISODE AVAILABLE` stays only when
    /// the hero play target is the immediate next episode after the CW row (finale drop);
    /// otherwise the user is behind and shelves own catch-up (e.g. CW E2, hero E11).
    private static func shouldExcludeFromHero(
        entry: HomeHeroFeedEntry,
        continueWatching: ContinueWatchingContext
    ) -> Bool {
        switch entry.presentation {
        case .movie(let movie):
            guard entry.eyebrow == .newlyAdded else { return false }
            return continueWatching.movieIDs.contains(movie.id)
        case .series(let series):
            guard let cwEpisode = continueWatching.episodeBySeriesID[series.id] else { return false }
            switch entry.eyebrow {
            case .newlyAdded:
                return true
            case .newEpisodeAvailable:
                guard case .episode(let playEpisode) = entry.playTarget else { return true }
                return !isSequentialNextUp(from: cwEpisode, to: playEpisode)
            }
        case .episode:
            return false
        }
    }

    private struct ContinueWatchingContext {
        var movieIDs: Set<ItemID> = []
        var episodeBySeriesID: [ItemID: Episode] = [:]
    }

    private static func continueWatchingContext(from continueWatching: [Item]) -> ContinueWatchingContext {
        var context = ContinueWatchingContext()
        for item in continueWatching {
            switch item {
            case .movie(let movie):
                context.movieIDs.insert(movie.id)
            case .episode(let episode):
                if context.episodeBySeriesID[episode.seriesID] == nil {
                    context.episodeBySeriesID[episode.seriesID] = episode
                }
            case .series:
                break
            }
        }
        return context
    }

    /// True when `next` is S{n}E{m+1} or S{n+1}E1 immediately after `current`.
    static func isSequentialNextUp(from current: Episode, to next: Episode) -> Bool {
        guard current.seriesID == next.seriesID else { return false }
        guard let currentSeason = current.parentIndexNumber,
              let currentIndex = current.indexNumber,
              let nextSeason = next.parentIndexNumber,
              let nextIndex = next.indexNumber else { return false }
        if currentSeason == nextSeason {
            return nextIndex == currentIndex + 1
        }
        return nextSeason == currentSeason + 1 && nextIndex == 1
    }
}