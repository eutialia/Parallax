import Foundation
import JellyfinAPI
import ParallaxCore

extension BaseItemDto {
    func toItemDetail() -> ItemDetail? {
        guard let type else { return nil }
        let tagline = taglines?.first
        let studioNames = (studios ?? []).compactMap(\.name)
        let peopleNames = (people ?? []).compactMap(\.name)
        // `BaseItemPerson.type` is the `PersonKind?` enum (`.director` = "Director"). Preserve the
        // SDK's order and dedupe — a person can be listed twice (e.g. director + writer credits).
        let directorNames = (people ?? [])
            .filter { $0.type == .director }
            .compactMap(\.name)
            .reduce(into: [String]()) { acc, name in if !acc.contains(name) { acc.append(name) } }
        let mappedChapters: [Chapter] = (chapters ?? []).enumerated().compactMap { i, ch in
            guard let ticks = ch.startPositionTicks else { return nil }
            return Chapter(index: i, name: ch.name, start: .microseconds(ticks / 10))
        }

        switch type {
        case .movie:
            guard let movie = toMovie() else { return nil }
            return .movie(MovieDetail(movie: movie, tagline: tagline, studios: studioNames, directors: directorNames, people: peopleNames, chapters: mappedChapters))
        case .series:
            guard let series = toSeries() else { return nil }
            return .series(SeriesDetail(series: series, tagline: tagline, studios: studioNames, people: peopleNames))
        case .season:
            guard let season = toSeason() else { return nil }
            return .season(SeasonDetail(season: season, overview: overview))
        case .episode:
            guard let episode = toEpisode() else { return nil }
            return .episode(EpisodeDetail(episode: episode, people: peopleNames, chapters: mappedChapters))
        default:
            return nil
        }
    }
}
