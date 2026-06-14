import Foundation

/// What a library grid is showing: one server-side collection, or the user's
/// favorites across every library (movies + series merged, queried recursively
/// with no parent — Jellyfin's `/Items?filters=IsFavorite`).
public enum LibraryScope: Sendable, Hashable {
    case collection(CollectionID)
    case favorites
}
