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

    @Test("a played-operation change does not drop a favorited item from the Favorites scope")
    func playedOperationDoesNotDropFavorite() async {
        let userDataActions = UserDataActions()
        let itemID = ItemID(rawValue: "movie-fav-played")
        let fake = FakeMediaRepository()
        fake.itemsResult = .success(Page(items: [movieItem(id: itemID.rawValue, isFavorite: true)], total: 1, nextCursor: nil))
        let vm = LibraryGridViewModel(repo: fake, scope: .favorites, userDataActions: userDataActions)
        await vm.load()
        #expect(vm.items.count == 1)

        // A real played-operation `UserItemData` from Jellyfin omits the favorite field, which
        // `UserItemDataDto.toUserItemData()` maps absent -> false. Without gating the removal on
        // `operation == .favorite`, this would misread as an unfavorite and vanish the item.
        let played = UserItemData(played: true, playbackPositionTicks: 0, playCount: 1, isFavorite: false)
        let writer = StubWriter(favorite: .success(played))
        _ = await userDataActions.togglePlayed(itemID: itemID, currentlyPlayed: false, via: writer)

        await waitUntil { vm.items.first?.userData.played == true }
        #expect(vm.items.count == 1)
        // The in-place patch merges the payload, so the untrustworthy `isFavorite: false` on a
        // played response must not overwrite the item's real (favorited) state.
        #expect(vm.items.first?.userData.isFavorite == true)
    }

    @Test("a favorite-operation change patched in place does not reset an item's watch progress")
    func favoriteOperationDoesNotResetProgress() async {
        let userDataActions = UserDataActions()
        let itemID = ItemID(rawValue: "movie-progress-fav")
        let fake = FakeMediaRepository()
        var item = movieItem(id: itemID.rawValue, isFavorite: false)
        item = item.withUserData(UserItemData(played: false, playbackPositionTicks: 54_321, playCount: 0, isFavorite: false))
        fake.itemsResult = .success(Page(items: [item], total: 1, nextCursor: nil))
        let vm = LibraryGridViewModel(repo: fake, scope: .collection(CollectionID(rawValue: "movies")), userDataActions: userDataActions)
        await vm.load()
        #expect(vm.items.first?.userData.playbackPositionTicks == 54_321)

        // A real favorite-operation `UserItemData` from Jellyfin omits played/position, which
        // `UserItemDataDto.toUserItemData()` maps absent -> false/0. Without merging, this
        // would wrongly zero the item's real resume position.
        let favorited = UserItemData(played: false, playbackPositionTicks: 0, playCount: 0, isFavorite: true)
        let writer = StubWriter(favorite: .success(favorited))
        _ = await userDataActions.toggleFavorite(itemID: itemID, currentlyFavorite: false, via: writer)

        await waitUntil { vm.items.first?.userData.isFavorite == true }
        #expect(vm.items.first?.userData.playbackPositionTicks == 54_321)
    }
}
