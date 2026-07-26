import Foundation
import Testing
import ParallaxCore
import ParallaxJellyfin
@testable import Parallax

extension Tag {
    /// Tests that stand up real machinery (a loopback HTTP server, a libvlc decode) rather than a
    /// fake. Slow and environment-dependent by nature, so a fast unit run can exclude them with
    /// `--skip-tag integration`.
    @Tag static var integration: Self
}

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

/// A `JellyfinClientFactory` for suites that must construct a `SessionManager` (view models take
/// one) but never reach the network. It only satisfies the initializer, and traps if a test ever
/// does walk into it — a call here means the suite is exercising a path it didn't intend to.
struct UnusedJellyfinClientFactory: JellyfinClientFactory {
    func make(serverURL: URL) async -> JellyfinAuthClient {
        fatalError("JellyfinClientFactory.make must not be reached in this suite")
    }
}

/// A `ServerStore` on a fresh, per-call `UserDefaults` suite, so persisted servers never leak
/// between tests or into the standard domain. `label` just makes the suite name greppable.
///
/// Prefer `withIsolatedServerStore(label:_:)` where the test can be scoped — this variant leaves the
/// suite's plist behind, which accumulates across runs.
func makeIsolatedServerStore(label: String) -> ServerStore {
    let suiteName = "\(label)-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    return ServerStore(settings: SettingsStore(defaults: defaults), keychain: FakeKeychain())
}

/// `makeIsolatedServerStore` with the domain removed however `body` exits, so a test that actually
/// WRITES servers doesn't leave a plist behind on the host.
func withIsolatedServerStore<Result>(
    label: String,
    isolation: isolated (any Actor)? = #isolation,
    _ body: (ServerStore) async throws -> Result
) async throws -> Result {
    let suiteName = "\(label)-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    defer { defaults.removePersistentDomain(forName: suiteName) }
    return try await body(ServerStore(settings: SettingsStore(defaults: defaults), keychain: FakeKeychain()))
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
