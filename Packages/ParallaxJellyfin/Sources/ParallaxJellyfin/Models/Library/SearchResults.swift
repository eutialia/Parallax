import Foundation

public struct SearchResults: Sendable, Hashable {
    public let movies: [Movie]
    public let series: [Series]
    public let episodes: [Episode]

    public init(movies: [Movie], series: [Series], episodes: [Episode]) {
        self.movies = movies
        self.series = series
        self.episodes = episodes
    }

    public static let empty = SearchResults(movies: [], series: [], episodes: [])
}
