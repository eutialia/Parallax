import Foundation

public enum ItemDetail: Sendable, Hashable, Identifiable {
    case movie(MovieDetail)
    case series(SeriesDetail)
    case season(SeasonDetail)
    case episode(EpisodeDetail)

    public var id: ItemID {
        switch self {
        case .movie(let d): return d.movie.id
        case .series(let d): return d.series.id
        case .season(let d): return d.season.id
        case .episode(let d): return d.episode.id
        }
    }
}

public struct MovieDetail: Sendable, Hashable {
    public let movie: Movie
    public let tagline: String?
    public let studios: [String]
    /// Directors, extracted from the typed people list — the ledger surfaces them on their own
    /// row. (Series carry per-episode directors, so `SeriesDetail` has no equivalent.)
    public let directors: [String]
    public let people: [String]   // simplified — full Person type lands in Phase 4
    public let chapters: [Chapter]

    public init(movie: Movie, tagline: String?, studios: [String], directors: [String], people: [String], chapters: [Chapter] = []) {
        self.movie = movie; self.tagline = tagline
        self.studios = studios; self.directors = directors
        self.people = people
        self.chapters = chapters
    }
}

public struct SeriesDetail: Sendable, Hashable {
    public let series: Series
    public let tagline: String?
    public let studios: [String]
    public let people: [String]

    public init(series: Series, tagline: String?, studios: [String], people: [String]) {
        self.series = series; self.tagline = tagline
        self.studios = studios; self.people = people
    }
}

public struct SeasonDetail: Sendable, Hashable {
    public let season: Season
    public let overview: String?

    public init(season: Season, overview: String?) {
        self.season = season; self.overview = overview
    }
}

public struct EpisodeDetail: Sendable, Hashable {
    public let episode: Episode
    public let people: [String]
    public let chapters: [Chapter]

    public init(episode: Episode, people: [String], chapters: [Chapter] = []) {
        self.episode = episode; self.people = people
        self.chapters = chapters
    }
}
