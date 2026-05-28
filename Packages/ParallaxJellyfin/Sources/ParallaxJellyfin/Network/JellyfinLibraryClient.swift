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
    func search(query: String, scope: SearchScope) async throws -> [BaseItemDto]
}
