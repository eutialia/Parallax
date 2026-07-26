import Testing
import Foundation
import ParallaxCore
import ParallaxJellyfin
@testable import Parallax

/// `LibraryGridViewModel`'s `UserDataActions.changes()` subscription: a matching item's
/// `userData` patches in place, and a Favorites-scope grid drops an item once it's no longer
/// a favorite. Covers the one VM in this task's set that's backed by a protocol (`MediaRepository`,
/// via `FakeMediaRepository`) rather than the concrete `LibraryRepository` — see the task report
/// for why Home/MovieDetail/SeriesDetail/Search aren't covered here.
@MainActor
@Suite("LibraryGridViewModel user-data subscription")
struct LibraryGridViewModelUserDataTests {
    @Test("a change patches a matching item's userData in place")
    func patchesMatchingItem() async {
        let userDataActions = UserDataActions()
        let itemID = ItemID(rawValue: "movie-patch")
        let fake = FakeMediaRepository()
        fake.itemsResult = .success(makePage([makeMovieItem(itemID.rawValue, title: "Example", isFavorite: false)]))
        let vm = LibraryGridViewModel(repo: fake, source: testJellyfinSource, scope: .collection(CollectionID(rawValue: "movies")), userDataActions: userDataActions)
        await vm.load()
        #expect(vm.items.first?.userData.isFavorite == false)

        let fresh = UserItemData(played: false, playbackPositionTicks: 0, playCount: 0, isFavorite: true)
        let writer = StubUserDataWriter(favorite: .success(fresh))
        _ = await userDataActions.toggleFavorite(itemID: itemID, source: testJellyfinSource, currentlyFavorite: false, via: writer)

        await waitUntil { vm.items.first?.userData.isFavorite == true }
        #expect(vm.items.first?.userData.isFavorite == true)
    }

    @Test("a Favorites-scope grid drops an item once it's no longer a favorite")
    func favoritesScopeDropsUnfavorited() async {
        let userDataActions = UserDataActions()
        let itemID = ItemID(rawValue: "movie-fav")
        let fake = FakeMediaRepository()
        fake.itemsResult = .success(makePage([makeMovieItem(itemID.rawValue, title: "Example", isFavorite: true)]))
        let vm = LibraryGridViewModel(repo: fake, source: testJellyfinSource, scope: .favorites, userDataActions: userDataActions)
        await vm.load()
        #expect(vm.items.count == 1)

        let fresh = UserItemData(played: false, playbackPositionTicks: 0, playCount: 0, isFavorite: false)
        let writer = StubUserDataWriter(favorite: .success(fresh))
        _ = await userDataActions.toggleFavorite(itemID: itemID, source: testJellyfinSource, currentlyFavorite: true, via: writer)

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
        fake.itemsResult = .success(makePage([makeMovieItem(itemID.rawValue, title: "Example", isFavorite: true)]))
        let vm = LibraryGridViewModel(repo: fake, source: testJellyfinSource, scope: .favorites, userDataActions: userDataActions)
        await vm.load()
        #expect(vm.items.count == 1)

        // A real played-operation `UserItemData` from Jellyfin omits the favorite field, which
        // `UserItemDataDto.toUserItemData()` maps absent -> false. Without gating the removal on
        // `operation == .favorite`, this would misread as an unfavorite and vanish the item.
        let played = UserItemData(played: true, playbackPositionTicks: 0, playCount: 1, isFavorite: false)
        // `togglePlayed` below drives `setPlayed`, not `setFavorite` — pass `played`
        // explicitly (the shared stub's two result fields are independent, unlike the old
        // file-local `StubWriter` this replaced, which returned the same `favoriteResult` for
        // both operations).
        let writer = StubUserDataWriter(favorite: .success(played), played: .success(played))
        _ = await userDataActions.togglePlayed(itemID: itemID, source: testJellyfinSource, currentlyPlayed: false, via: writer)

        await waitUntil { vm.items.first?.userData.played == true }
        #expect(vm.items.count == 1)
        // The in-place patch merges the payload, so the untrustworthy `isFavorite: false` on a
        // played response must not overwrite the item's real (favorited) state.
        #expect(vm.items.first?.userData.isFavorite == true)
    }

    /// The (source, itemID) key, from the grid's side. Jellyfin derives item GUIDs deterministically
    /// from the media path, so two servers over a mirrored library genuinely mint the SAME id — and
    /// independently of any collision, favoriting on one server must never repaint another server's
    /// tile. A grid matching on `itemID` alone passes every other test in this suite.
    @Test("a change from a DIFFERENT source is ignored, even for an identical item id")
    func ignoresChangesFromAnotherSource() async {
        let userDataActions = UserDataActions()
        let itemID = ItemID(rawValue: "mirrored-guid")
        let otherServer = MediaSourceID.jellyfin(ServerID(rawValue: "other-server"))
        let fake = FakeMediaRepository()
        fake.itemsResult = .success(makePage([makeMovieItem(itemID.rawValue, title: "Example", isFavorite: true)]))
        let vm = LibraryGridViewModel(repo: fake, source: testJellyfinSource, scope: .favorites, userDataActions: userDataActions)
        await vm.load()
        #expect(vm.items.count == 1)

        // An unfavorite on the OTHER server: same item id, so an id-only match would drop this
        // grid's row (Favorites scope removes on `unfavorited`).
        let unfavorited = UserItemData(played: false, playbackPositionTicks: 0, playCount: 0, isFavorite: false)
        let writer = StubUserDataWriter(favorite: .success(unfavorited))
        _ = await userDataActions.toggleFavorite(itemID: itemID, source: otherServer, currentlyFavorite: true, via: writer)

        // Then a change this grid DOES own, on the same item, as the barrier: once its visible
        // effect has landed, the cross-source event ahead of it in the same serial stream has
        // provably been processed — and ignored, or there'd be no row left to patch.
        let played = UserItemData(played: true, playbackPositionTicks: 0, playCount: 1, isFavorite: true)
        let playedWriter = StubUserDataWriter(favorite: .success(played), played: .success(played))
        _ = await userDataActions.togglePlayed(itemID: itemID, source: testJellyfinSource, currentlyPlayed: false, via: playedWriter)
        await waitUntil { vm.items.first?.userData.played == true }

        #expect(vm.items.map(\.id.rawValue) == [itemID.rawValue])
        #expect(vm.items.first?.userData.isFavorite == true)
    }

    @Test("a favorite-operation change patched in place does not reset an item's watch progress")
    func favoriteOperationDoesNotResetProgress() async {
        let userDataActions = UserDataActions()
        let itemID = ItemID(rawValue: "movie-progress-fav")
        let fake = FakeMediaRepository()
        var item = makeMovieItem(itemID.rawValue, title: "Example", isFavorite: false)
        item = item.withUserData(UserItemData(played: false, playbackPositionTicks: 54_321, playCount: 0, isFavorite: false))
        fake.itemsResult = .success(makePage([item]))
        let vm = LibraryGridViewModel(repo: fake, source: testJellyfinSource, scope: .collection(CollectionID(rawValue: "movies")), userDataActions: userDataActions)
        await vm.load()
        #expect(vm.items.first?.userData.playbackPositionTicks == 54_321)

        // A real favorite-operation `UserItemData` from Jellyfin omits played/position, which
        // `UserItemDataDto.toUserItemData()` maps absent -> false/0. Without merging, this
        // would wrongly zero the item's real resume position.
        let favorited = UserItemData(played: false, playbackPositionTicks: 0, playCount: 0, isFavorite: true)
        let writer = StubUserDataWriter(favorite: .success(favorited))
        _ = await userDataActions.toggleFavorite(itemID: itemID, source: testJellyfinSource, currentlyFavorite: false, via: writer)

        await waitUntil { vm.items.first?.userData.isFavorite == true }
        #expect(vm.items.first?.userData.playbackPositionTicks == 54_321)
    }
}
