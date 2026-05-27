import Foundation

public struct ItemSort: Sendable, Hashable {
    public let field: Field
    public let direction: Direction

    public init(field: Field, direction: Direction) {
        self.field = field
        self.direction = direction
    }

    public enum Field: Sendable, Hashable, CaseIterable {
        case title              // SortName
        case dateAdded          // DateCreated
        case releaseDate        // PremiereDate
        case communityRating
        case officialRating
        case runtime
        case playCount
        case random
    }

    public enum Direction: Sendable, Hashable, CaseIterable {
        case ascending
        case descending
    }

    public static let defaultForLibrary = ItemSort(field: .title, direction: .ascending)
}
