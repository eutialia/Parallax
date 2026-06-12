import Foundation

public struct ItemSort: Sendable, Hashable {
    public let field: Field
    public let direction: Direction

    public init(field: Field, direction: Direction) {
        self.field = field
        self.direction = direction
    }

    public enum Field: Sendable, Hashable, CaseIterable {
        case releaseDate        // PremiereDate
        case dateAdded          // DateCreated
        case title              // SortName
        case communityRating
        case officialRating

        /// The direction a freshly picked field starts in — the ordering people
        /// mean when they tap the field name: dates newest-first, titles A→Z,
        /// ratings highest-first. The UI resets to this on every field switch so
        /// "Title" never inherits a stale Z→A from a previous "Newest" pick.
        public var naturalDirection: Direction {
            switch self {
            case .title: return .ascending
            case .releaseDate, .dateAdded, .communityRating, .officialRating: return .descending
            }
        }
    }

    public enum Direction: Sendable, Hashable, CaseIterable {
        case ascending
        case descending
    }

    public static let defaultForLibrary = ItemSort(field: .releaseDate, direction: .descending)
}
