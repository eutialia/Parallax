import Foundation

public struct ItemFilter: Sendable, Hashable {
    public var watchState: WatchState
    public var favoritesOnly: Bool
    public var genres: [String]

    public init(watchState: WatchState = .all, favoritesOnly: Bool = false, genres: [String] = []) {
        self.watchState = watchState
        self.favoritesOnly = favoritesOnly
        self.genres = genres
    }

    public enum WatchState: Sendable, Hashable, CaseIterable {
        case all
        case played
        case unplayed
    }
}
