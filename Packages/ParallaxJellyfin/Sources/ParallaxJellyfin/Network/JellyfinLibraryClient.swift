import Foundation
import JellyfinAPI

// Narrow protocol that LibraryRepository calls. Implementations:
//   - DefaultJellyfinLibraryClient (production, wraps a real JellyfinClient)
//   - FakeJellyfinLibraryClient (tests, programmable canned responses)
//
// Exposes BaseItemDto on purpose — DTO translation happens in the
// repository, not here. Mirrors Phase 2's JellyfinAuthClient shape.
public protocol JellyfinLibraryClient: Sendable {
    func getCollections() async throws -> [BaseItemDto]
    func getItems(parentID: String, filter: ItemFilter, sort: ItemSort, startIndex: Int, limit: Int) async throws -> (items: [BaseItemDto], total: Int)
    func getItemDetail(itemID: String) async throws -> BaseItemDto
    func getSeasons(seriesID: String) async throws -> [BaseItemDto]
    func getEpisodes(seasonID: String) async throws -> [BaseItemDto]
    func getContinueWatching() async throws -> [BaseItemDto]
    func getNextUp() async throws -> [BaseItemDto]
    /// Latest movies/series added across libraries (`GET /Items/Latest`).
    func getRecentlyAdded(limit: Int) async throws -> [BaseItemDto]
    func search(query: String, scope: SearchScope) async throws -> [BaseItemDto]
    /// POST/DELETE the item's favorite flag for the current user (`/UserFavoriteItems/{id}`).
    func setFavorite(itemID: String, isFavorite: Bool) async throws -> UserItemData
    /// Mark the item (movie/episode/season/series) played or unplayed for the current user.
    func setPlayed(itemID: String, isPlayed: Bool) async throws
    /// The single resume/next-up episode for a series (Jellyfin /Shows/NextUp?seriesId=),
    /// or nil when the series is unwatched-from-start / finished.
    func seriesNextUp(seriesID: String) async throws -> BaseItemDto?
    /// Distinct genre names available under a library/collection (Jellyfin /Genres?parentId=).
    func genres(parentID: String) async throws -> [String]
}
