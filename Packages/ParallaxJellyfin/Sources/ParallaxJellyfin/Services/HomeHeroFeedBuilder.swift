import Foundation

public enum HomeHeroFeedBuilder {
    public static let defaultImportWindow: TimeInterval = 24 * 60 * 60

    public static func build(
        latestItems: [Item],
        seriesByID: [String: Series],
        firstEpisodeBySeriesID: [String: Episode],
        limit: Int,
        importWindow: TimeInterval = defaultImportWindow
    ) -> [HomeHeroFeedEntry] {
        var movies: [(item: Item, date: Date)] = []
        var episodesBySeries: [String: [Episode]] = [:]

        for item in latestItems {
            switch item {
            case .movie(let movie):
                if let date = movie.dateAdded { movies.append((.movie(movie), date)) }
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

        for (seriesID, episodes) in episodesBySeries {
            guard let series = seriesByID[seriesID] else { continue }
            let presentation: Item = .series(series)
            let newest = episodes.max(by: { ($0.dateAdded ?? .distantPast) < ($1.dateAdded ?? .distantPast) })!
            let newestDate = newest.dateAdded ?? .distantPast
            let eyebrow = classifyEyebrow(
                seriesDate: series.dateAdded,
                newestEpisodeDate: newestDate,
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

        return entries
            .sorted { $0.date > $1.date }
            .prefix(limit)
            .map(\.entry)
    }

    private static func classifyEyebrow(
        seriesDate: Date?,
        newestEpisodeDate: Date,
        window: TimeInterval
    ) -> HeroEyebrow {
        guard let seriesDate else { return .newEpisodeAvailable }
        if abs(newestEpisodeDate.timeIntervalSince(seriesDate)) <= window {
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
}