import Foundation
import ParallaxCore
@testable import Parallax

/// Bounded yield loop shared by every test that waits on an async subscription (a
/// `UserDataActions.changes()` broadcast, a `ConnectivityMonitor` path update, …): hands
/// control to the subscriber's `for await` Task until it has processed the value, without a
/// wall-clock sleep. Safe because everything under test runs on the MainActor cooperative
/// executor — yielding is enough to let the subscription's task advance.
@MainActor
func waitUntil(_ condition: @MainActor () -> Bool) async {
    for _ in 0..<1000 where !condition() {
        await Task.yield()
    }
}

/// A `UserDataWriting` with canned, per-call results for each operation, independently — no
/// gate. Shared by every suite that just needs a stubbed favorite/played write; the one suite
/// that needs to deterministically park a call mid-flight (to exercise the in-flight guard)
/// keeps its own `GatedWriter` local (`UserDataActionsTests`).
final class StubUserDataWriter: UserDataWriting, @unchecked Sendable {
    var favoriteResult: Result<UserItemData, Error>
    var playedResult: Result<UserItemData, Error>

    init(
        favorite: Result<UserItemData, Error>,
        played: Result<UserItemData, Error> = .success(UserItemData(played: false, playbackPositionTicks: 0, playCount: 0, isFavorite: false))
    ) {
        self.favoriteResult = favorite
        self.playedResult = played
    }

    func setFavorite(itemID: ItemID, isFavorite: Bool) async throws -> UserItemData { try favoriteResult.get() }
    func setPlayed(itemID: ItemID, isPlayed: Bool) async throws -> UserItemData { try playedResult.get() }
}
