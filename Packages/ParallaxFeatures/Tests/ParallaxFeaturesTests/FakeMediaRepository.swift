import Foundation
import ParallaxCore

/// Canned `MediaRepository` for the view-model suites.
///
/// `@unchecked Sendable` with a lock, not with bare vars: `MediaRepository`'s methods are
/// nonisolated `async`, so a `@MainActor` view model's call runs the body off the main actor and
/// the recorders below are written from the cooperative pool while tests read them from the
/// MainActor. Unguarded, that read came back stale (a `nil` `lastSort` immediately after an
/// awaited load) under the parallel full-suite run — a flake in the test, not in the app.
final class FakeMediaRepository: MediaRepository, @unchecked Sendable {
    private let lock = NSLock()

    private var _collectionsResult: Result<[MediaCollection], Error> = .success([])
    private var _itemsResult: Result<Page<Item>, Error> = .success(Page(items: [], total: 0, nextCursor: nil))
    private var _genresResult: Result<[String], Error> = .success([])
    private var _lastSort: ItemSort?
    private var _lastFilter: ItemFilter?

    var collectionsResult: Result<[MediaCollection], Error> {
        get { lock.withLock { _collectionsResult } }
        set { lock.withLock { _collectionsResult = newValue } }
    }

    var itemsResult: Result<Page<Item>, Error> {
        get { lock.withLock { _itemsResult } }
        set { lock.withLock { _itemsResult = newValue } }
    }

    var genresResult: Result<[String], Error> {
        get { lock.withLock { _genresResult } }
        set { lock.withLock { _genresResult = newValue } }
    }

    /// The sort/filter the last `items` call asked for — lets a test assert that a coordinator
    /// actually pushed its choice down to this server rather than only recording it locally.
    var lastSort: ItemSort? { lock.withLock { _lastSort } }
    var lastFilter: ItemFilter? { lock.withLock { _lastFilter } }

    func collections() async throws -> [MediaCollection] { try collectionsResult.get() }

    func items(in scope: LibraryScope, filter: ItemFilter, sort: ItemSort, cursor: PageCursor?) async throws -> Page<Item> {
        let result: Result<Page<Item>, Error> = lock.withLock {
            _lastSort = sort
            _lastFilter = filter
            return _itemsResult
        }
        return try result.get()
    }

    func genres(in scope: LibraryScope) async throws -> [String] { try genresResult.get() }
}
