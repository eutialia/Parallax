import Foundation

public struct ItemFilter: Sendable, Hashable {
    public var watchState: WatchState
    public var favoritesOnly: Bool

    public init(watchState: WatchState = .all, favoritesOnly: Bool = false) {
        self.watchState = watchState
        self.favoritesOnly = favoritesOnly
    }

    public enum WatchState: Sendable, Hashable, CaseIterable {
        case all
        case played
        case unplayed
    }
}
