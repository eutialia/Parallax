import Foundation
import ParallaxCore

final class FakeMediaRepository: MediaRepository, @unchecked Sendable {
    var collectionsResult: Result<[MediaCollection], Error> = .success([])
    var itemsResult: Result<Page<Item>, Error> = .success(Page(items: [], total: 0, nextCursor: nil))
    var genresResult: Result<[String], Error> = .success([])

    /// The sort/filter the last `items` call asked for — lets a test assert that a coordinator
    /// actually pushed its choice down to this server rather than only recording it locally.
    private(set) var lastSort: ItemSort?
    private(set) var lastFilter: ItemFilter?

    func collections() async throws -> [MediaCollection] { try collectionsResult.get() }

    func items(in scope: LibraryScope, filter: ItemFilter, sort: ItemSort, cursor: PageCursor?) async throws -> Page<Item> {
        lastSort = sort
        lastFilter = filter
        return try itemsResult.get()
    }

    func genres(in scope: LibraryScope) async throws -> [String] { try genresResult.get() }
}
