import Foundation

/// Library-grid filtering. Watch state and favorites left this struct on purpose:
/// played titles are marked on the tile itself, and favorites became their own
/// library scope (`LibraryScope.favorites`) — genre is the one remaining filter.
public struct ItemFilter: Sendable, Hashable {
    public var genres: [String]

    public init(genres: [String] = []) {
        self.genres = genres
    }
}
