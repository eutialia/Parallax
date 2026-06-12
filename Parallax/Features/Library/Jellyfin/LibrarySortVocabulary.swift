import Foundation
import ParallaxJellyfin

/// One vocabulary for the library sort UI on every platform — the iOS nav-bar
/// menu (`LibrarySortMenuButton`) and the tvOS header chip read the same field
/// names and the same human direction pairs, so "Newest" means the same thing
/// everywhere or nowhere.
enum LibrarySortVocabulary {
    /// Human-language direction pair for a field — what ascending/descending
    /// MEAN for that field, natural order first. Replaces the old
    /// Ascending/Descending arrows nobody should have to decode.
    struct DirectionOption {
        let title: String
        let icon: String
        let direction: ItemSort.Direction
    }

    static func label(for field: ItemSort.Field) -> String {
        switch field {
        case .title: return "Title"
        case .dateAdded: return "Date Added"
        case .releaseDate: return "Release Date"
        case .communityRating: return "Rating"
        case .officialRating: return "Parental Rating"
        }
    }

    static func directionOptions(for field: ItemSort.Field) -> [DirectionOption] {
        switch field {
        case .releaseDate, .dateAdded:
            return [
                DirectionOption(title: "Newest", icon: "clock", direction: .descending),
                DirectionOption(title: "Oldest", icon: "clock.arrow.circlepath", direction: .ascending),
            ]
        case .title:
            return [
                DirectionOption(title: "A to Z", icon: "a.square", direction: .ascending),
                DirectionOption(title: "Z to A", icon: "z.square", direction: .descending),
            ]
        case .communityRating:
            return [
                DirectionOption(title: "Highest", icon: "star.fill", direction: .descending),
                DirectionOption(title: "Lowest", icon: "star", direction: .ascending),
            ]
        case .officialRating:
            return [
                DirectionOption(title: "Highest", icon: "arrow.up", direction: .descending),
                DirectionOption(title: "Lowest", icon: "arrow.down", direction: .ascending),
            ]
        }
    }
}
