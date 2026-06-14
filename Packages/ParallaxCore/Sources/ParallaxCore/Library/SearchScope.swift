import Foundation

public enum SearchScope: Sendable, Hashable, CaseIterable {
    case all
    case movies
    case series
    case episodes
}
