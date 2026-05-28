import Foundation
import JellyfinAPI

extension BaseItemDto {
    func toItemDetail() -> ItemDetail? {
        guard let type else { return nil }
        let tagline = taglines?.first
        let studioNames = (studios ?? []).compactMap(\.name)
        let peopleNames = (people ?? []).compactMap(\.name)

        switch type {
        case .movie:
            guard let movie = toMovie() else { return nil }
            return .movie(MovieDetail(movie: movie, tagline: tagline, studios: studioNames, people: peopleNames))
        case .series:
            guard let series = toSeries() else { return nil }
            return .series(SeriesDetail(series: series, tagline: tagline, studios: studioNames, people: peopleNames))
        case .season:
            guard let season = toSeason() else { return nil }
            return .season(SeasonDetail(season: season, overview: overview))
        case .episode:
            guard let episode = toEpisode() else { return nil }
            return .episode(EpisodeDetail(episode: episode, people: peopleNames))
        default:
            return nil
        }
    }
}
