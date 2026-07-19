import Foundation
import ParallaxCore
import ParallaxJellyfin

/// The write surface `UserDataActions` needs from a per-session repository — exactly the
/// two Jellyfin user-data mutations. `LibraryRepository` satisfies it verbatim (the
/// conformance below is declaration-only), so a caller always hands in the repo it already
/// built for the item's session; the service never picks a server itself. A narrow protocol
/// (not the concrete actor) keeps the service unit-testable with a fake, mirroring how
/// `MediaRepository` abstracts the browse surface.
protocol UserDataWriting: Sendable {
    func setFavorite(itemID: ItemID, isFavorite: Bool) async throws -> UserItemData
    @discardableResult
    func setPlayed(itemID: ItemID, isPlayed: Bool) async throws -> UserItemData
}

extension LibraryRepository: UserDataWriting {}

/// Performs Jellyfin user-data mutations (favorite / played) for every surface and
/// broadcasts the result so any screen showing that item can reflect it — the single
/// service the context-menu wave's cross-screen updates are built on.
///
/// One in-flight guard per (`ItemID`, operation) so rapid taps or two surfaces toggling the
/// same item don't issue parallel writes; favorite and played are guarded independently, so
/// toggling one never coalesces the other on the same item (ported from the old
/// `FavoriteToggle`, which guarded favorites alone).
///
/// App-root injected via `.environment(...)` like `PlaybackPresenter`; callers hand in the
/// `LibraryRepository` they already resolved for the item's session (playback is per-server
/// here — the service never assumes a primary).
@Observable
@MainActor
final class UserDataActions {
    /// A committed user-data mutation, broadcast to every subscriber on success. `userData`
    /// is the server's fresh copy for `itemID`.
    ///
    /// SERIES CASCADE: marking a *series* played cascades server-side to all its episodes,
    /// but this event still carries only the series `ItemID` + its own `UserItemData` — the
    /// service does NOT fan out a per-episode event. A subscriber holding episodes of that
    /// series must treat a series-level change as "my episodes are now stale, refetch"; it
    /// cannot learn each episode's new flag from this event.
    struct Change: Sendable {
        let itemID: ItemID
        let userData: UserItemData
    }

    /// Result of a toggle, shaped to drive the caller's optimistic UI: `.success` carries the
    /// server's fresh data, `.skipped` means an identical write was already in flight (the
    /// guard coalesced it), `.failure` carries the error so the caller can revert. Only
    /// `.success` broadcasts a `Change`.
    enum Outcome: Sendable {
        case success(UserItemData)
        case skipped
        case failure(AppError)
    }

    private enum Operation: Hashable { case favorite, played }
    private struct InFlightKey: Hashable {
        let itemID: ItemID
        let operation: Operation
    }

    @ObservationIgnored private var inFlight = Set<InFlightKey>()
    @ObservationIgnored private var subscribers: [UUID: AsyncStream<Change>.Continuation] = [:]

    // MARK: - Subscription

    /// A change feed for one subscriber. Ownership is the returned stream's: iterate it from a
    /// `Task` the subscriber owns and cancel that task when the subscriber dies (e.g. an
    /// `@Observable` VM stores the `Task` and cancels it in `deinit`). Cancellation ends the
    /// `for await`, which fires `onTermination` and drops the continuation from the registry —
    /// so a dead subscriber leaves nothing behind, with no manual unregister call and no
    /// retain of the subscriber here.
    func changes() -> AsyncStream<Change> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<Change>.makeStream()
        subscribers[id] = continuation
        continuation.onTermination = { _ in
            // onTermination runs off the actor — hop back on to drop the entry.
            Task { @MainActor [weak self] in self?.subscribers[id] = nil }
        }
        return stream
    }

    // MARK: - Actions

    func toggleFavorite(
        itemID: ItemID,
        currentlyFavorite: Bool,
        via repo: some UserDataWriting
    ) async -> Outcome {
        await perform(.favorite, itemID: itemID) {
            try await repo.setFavorite(itemID: itemID, isFavorite: !currentlyFavorite)
        }
    }

    func togglePlayed(
        itemID: ItemID,
        currentlyPlayed: Bool,
        via repo: some UserDataWriting
    ) async -> Outcome {
        await perform(.played, itemID: itemID) {
            try await repo.setPlayed(itemID: itemID, isPlayed: !currentlyPlayed)
        }
    }

    // MARK: - Internals

    /// Shared guard + broadcast for both operations. The guard is synchronous around the
    /// `await`, so a second call for the same key sees the insert fail and returns `.skipped`
    /// before issuing a parallel write.
    private func perform(
        _ operation: Operation,
        itemID: ItemID,
        _ write: () async throws -> UserItemData
    ) async -> Outcome {
        let key = InFlightKey(itemID: itemID, operation: operation)
        guard inFlight.insert(key).inserted else { return .skipped }
        defer { inFlight.remove(key) }

        do {
            let userData = try await write()
            broadcast(Change(itemID: itemID, userData: userData))
            return .success(userData)
        } catch let error as AppError {
            return .failure(error)
        } catch {
            return .failure(.unexpected("User-data toggle failed.", underlying: AnySendableError(error)))
        }
    }

    private func broadcast(_ change: Change) {
        for continuation in subscribers.values {
            continuation.yield(change)
        }
    }
}
