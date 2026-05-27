import Foundation

public enum CollectionType: Sendable, Hashable {
    case movies
    case tvShows
    case other(String)
}
