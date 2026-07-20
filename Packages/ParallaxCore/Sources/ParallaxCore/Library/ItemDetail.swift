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
    /// `var` only for the `withMovie` copy below; immutable to callers.
    public private(set) var movie: Movie
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

    /// Same detail, updated movie. A mutated copy — NOT an init call listing every field,
    /// which silently zeroes any field someone forgot to thread through as the struct grows.
    public func withMovie(_ movie: Movie) -> MovieDetail {
        var copy = self; copy.movie = movie; return copy
    }
}

public struct SeriesDetail: Sendable, Hashable {
    /// `var` only for the `withSeries` copy below; immutable to callers.
    public private(set) var series: Series
    public let tagline: String?
    public let studios: [String]
    public let people: [String]

    public init(series: Series, tagline: String?, studios: [String], people: [String]) {
        self.series = series; self.tagline = tagline
        self.studios = studios; self.people = people
    }

    /// Same detail, updated series. A mutated copy — NOT an init call listing every field,
    /// which silently zeroes any field someone forgot to thread through as the struct grows.
    public func withSeries(_ series: Series) -> SeriesDetail {
        var copy = self; copy.series = series; return copy
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
