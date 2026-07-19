import Testing
import Foundation
import ParallaxCore
@testable import Parallax

/// `LibraryGridViewModel`'s `UserDataActions.changes()` subscription: a matching item's
/// `userData` patches in place, and a Favorites-scope grid drops an item once it's no longer
/// a favorite. Covers the one VM in this task's set that's backed by a protocol (`MediaRepository`,
/// via `FakeMediaRepository`) rather than the concrete `LibraryRepository` — see the task report
/// for why Home/MovieDetail/SeriesDetail/Search aren't covered here.
@MainActor
@Suite("LibraryGridViewModel user-data subscription")
struct LibraryGridViewModelUserDataTests {
    /// A writer with a canned favorite result — no gate, mirrors `UserDataActionsTests.StubWriter`.
    private final class StubWriter: UserDataWriting, @unchecked Sendable {
        var favoriteResult: Result<UserItemData, Error>

        init(favorite: Result<UserItemData, Error>) { self.favoriteResult = favorite }

        func setFavorite(itemID: ItemID, isFavorite: Bool) async throws -> UserItemData { try favoriteResult.get() }
        func setPlayed(itemID: ItemID, isPlayed: Bool) async throws -> UserItemData { try favoriteResult.get() }
    }

    private func movieItem(id: String, isFavorite: Bool) -> Item {
        .movie(Movie(
            id: ItemID(rawValue: id), title: "Example", overview: nil, year: nil, runtime: nil,
            communityRating: nil, officialRating: nil, genres: [],
            primaryTag: nil, backdropTags: [], logoTag: nil, thumbTag: nil, dateAdded: nil,
            userData: UserItemData(played: false, playbackPositionTicks: 0, playCount: 0, isFavorite: isFavorite)
        ))
    }

    /// Bounded yield loop: hand control to the subscription's `for await` Task until it has
    /// processed the broadcast, without a wall-clock sleep (mirrors `ConnectivityMonitorTests`).
    private func waitUntil(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<1000 where !condition() {
            await Task.yield()
        }
    }

    @Test("a change patches a matching item's userData in place")
    func patchesMatchingItem() async {
        let userDataActions = UserDataActions()
        let itemID = ItemID(rawValue: "movie-patch")
        let fake = FakeMediaRepository()
        fake.itemsResult = .success(Page(items: [movieItem(id: itemID.rawValue, isFavorite: false)], total: 1, nextCursor: nil))
        let vm = LibraryGridViewModel(repo: fake, scope: .collection(CollectionID(rawValue: "movies")), userDataActions: userDataActions)
        await vm.load()
        #expect(vm.items.first?.userData.isFavorite == false)

        let fresh = UserItemData(played: false, playbackPositionTicks: 0, playCount: 0, isFavorite: true)
        let writer = StubWriter(favorite: .success(fresh))
        _ = await userDataActions.toggleFavorite(itemID: itemID, currentlyFavorite: false, via: writer)

        await waitUntil { vm.items.first?.userData.isFavorite == true }
        #expect(vm.items.first?.userData.isFavorite == true)
    }

    @Test("a Favorites-scope grid drops an item once it's no longer a favorite")
    func favoritesScopeDropsUnfavorited() async {
        let userDataActions = UserDataActions()
        let itemID = ItemID(rawValue: "movie-fav")
        let fake = FakeMediaRepository()
        fake.itemsResult = .success(Page(items: [movieItem(id: itemID.rawValue, isFavorite: true)], total: 1, nextCursor: nil))
        let vm = LibraryGridViewModel(repo: fake, scope: .favorites, userDataActions: userDataActions)
        await vm.load()
        #expect(vm.items.count == 1)

        let fresh = UserItemData(played: false, playbackPositionTicks: 0, playCount: 0, isFavorite: false)
        let writer = StubWriter(favorite: .success(fresh))
        _ = await userDataActions.toggleFavorite(itemID: itemID, currentlyFavorite: true, via: writer)

        await waitUntil { vm.items.isEmpty }
        #expect(vm.items.isEmpty)
        // Non-Favorites-scope stays .loaded throughout (never re-skeletons).
        #expect(vm.state == .loaded)
    }
}
