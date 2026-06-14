import Foundation
import ParallaxCore

final class FakeMediaRepository: MediaRepository, @unchecked Sendable {
    var collectionsResult: Result<[MediaCollection], Error> = .success([])
    var itemsResult: Result<Page<Item>, Error> = .success(Page(items: [], total: 0, nextCursor: nil))
    var genresResult: Result<[String], Error> = .success([])

    func collections() async throws -> [MediaCollection] { try collectionsResult.get() }
    func items(in scope: LibraryScope, filter: ItemFilter, sort: ItemSort, cursor: PageCursor?) async throws -> Page<Item> { try itemsResult.get() }
    func genres(in scope: LibraryScope) async throws -> [String] { try genresResult.get() }
}
