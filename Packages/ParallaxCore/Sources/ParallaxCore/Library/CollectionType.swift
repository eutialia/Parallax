import Foundation

public enum CollectionType: Sendable, Hashable {
    case movies
    case tvShows
    /// A library the server declares NO type for — Jellyfin's "mixed content", holding movies and
    /// shows side by side. Distinct from `.other` because it is browsable: the grid queries movies
    /// and series by parent id, which is exactly what a mixed library returns. Folding it into
    /// `.other` once made these libraries unreachable on every platform.
    case mixed
    /// A typed library this app has no browse surface for — music, photos, books, live TV. The
    /// associated value is the server's raw type string, kept for diagnostics.
    case other(String)

    /// Whether this app can actually open the collection. Music, photo, and book libraries come
    /// back from a Jellyfin server like any other view but have no browse surface here, so every
    /// library list drops them. Stated once, in the model, because it used to be re-derived as a
    /// private `isSupported` switch inside a single view — which left the iPad sidebar and tvOS
    /// root listing collections the iPhone list hid.
    ///
    /// Untyped libraries are browsable, NOT unknown-therefore-excluded: a deny-list is the safe
    /// direction here, because guessing "exclude" hides content the user definitely has, while
    /// guessing "include" at worst shows a library that opens empty.
    public var isBrowsable: Bool {
        switch self {
        case .movies, .tvShows, .mixed: return true
        case .other: return false
        }
    }
}
