import Foundation
import JellyfinAPI

/// Narrow protocol that `LibraryRepository` calls. Implementations:
///   - `DefaultJellyfinLibraryClient` (production, wraps a real `JellyfinClient`)
///   - `FakeJellyfinLibraryClient` (tests, programmable canned responses)
///
/// Exposes `BaseItemDto` on purpose — DTO translation happens in the repository, not here.
/// Mirrors the `JellyfinAuthClient` shape.
public protocol JellyfinLibraryClient: Sendable {
    /// The user's top-level library collections (Movies, Shows, …).
    func getCollections() async throws -> [BaseItemDto]
    /// A page of items in a scope, filtered and sorted; returns the page plus the total count.
    func getItems(scope: LibraryScope, filter: ItemFilter, sort: ItemSort, startIndex: Int, limit: Int) async throws -> (items: [BaseItemDto], total: Int)
    /// Full detail for a single item by id.
    func getItemDetail(itemID: String) async throws -> BaseItemDto
    /// Batch lookup by item id (e.g. season folders for home-shelf artwork).
    func getItemsByIDs(_ ids: [String]) async throws -> [BaseItemDto]
    /// The seasons of a series, in order.
    func getSeasons(seriesID: String) async throws -> [BaseItemDto]
    /// The episodes of a season, in order.
    func getEpisodes(seasonID: String) async throws -> [BaseItemDto]
    /// The user's Continue Watching shelf (in-progress items).
    func getContinueWatching() async throws -> [BaseItemDto]
    /// The user's Next Up shelf (next unwatched episode per series).
    func getNextUp() async throws -> [BaseItemDto]
    /// Latest items added across libraries (`GET /Items/Latest`).
    func getRecentlyAdded(limit: Int, includeItemTypes: [BaseItemKind]) async throws -> [BaseItemDto]
    /// Search items by free-text query within a scope (all / movies / shows / …).
    func search(query: String, scope: SearchScope) async throws -> [BaseItemDto]
    /// POST/DELETE the item's favorite flag for the current user (`/UserFavoriteItems/{id}`).
    func setFavorite(itemID: String, isFavorite: Bool) async throws -> UserItemData
    /// Mark the item (movie/episode/season/series) played or unplayed for the current user.
    func setPlayed(itemID: String, isPlayed: Bool) async throws
    /// The single resume/next-up episode for a series (Jellyfin /Shows/NextUp?seriesId=),
    /// or nil when the series is unwatched-from-start / finished.
    func seriesNextUp(seriesID: String) async throws -> BaseItemDto?
    /// Media segments (intro/outro markers) for an item — Jellyfin's native
    /// `GET /MediaSegments/{itemId}`. Empty unless a provider plugin analyzed it.
    func mediaSegments(itemID: String) async throws -> [MediaSegmentDto]
    /// The `adjacentTo` window for an episode (`GET /Shows/{seriesId}/Episodes`):
    /// up to three items — previous, the episode itself, next — in airing order,
    /// series-wide (no season filter, so it crosses season boundaries). The
    /// neighbor source for in-player succession.
    func adjacentEpisodes(seriesID: String, episodeID: String) async throws -> [BaseItemDto]
    /// Distinct genre names available in a scope (Jellyfin /Genres?parentId= for a
    /// collection, /Genres?isFavorite=true for the favorites scope).
    func genres(scope: LibraryScope) async throws -> [String]
}
