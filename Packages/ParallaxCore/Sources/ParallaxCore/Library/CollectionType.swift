import Foundation

public enum CollectionType: Sendable, Hashable {
    case movies
    case tvShows
    case other(String)

    /// Whether this app can actually open the collection. Music, photo, and book libraries come
    /// back from a Jellyfin server like any other view but have no browse surface here, so every
    /// library list drops them. Stated once, in the model, because it used to be re-derived as a
    /// private `isSupported` switch inside a single view — which left the iPad sidebar and tvOS
    /// root listing collections the iPhone list hid.
    public var isBrowsable: Bool {
        switch self {
        case .movies, .tvShows: return true
        case .other: return false
        }
    }
}
