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
///
/// Consumers patch via `Change.merged(into:)`, never by reading `Change`'s raw payload
/// directly — that's why the payload itself is deliberately inaccessible outside this type.
/// One operation's response may omit the other operation's fields (a DTO-boundary default,
/// not real state; see `merge` below), so a raw read risks adopting a stale/default value the
/// event never actually carried. The one narrow exception is `Change.unfavorited`, which reads
/// only the one field a Favorites-scope removal legitimately needs.
@Observable
@MainActor
final class UserDataActions {
    /// Which user-data field a `Change` came from. Lets a subscriber key its reaction on the
    /// operation itself (e.g. "any played change" ) instead of diffing its own cached copy of
    /// the item against the incoming `userData`.
    enum Operation: Hashable, Sendable { case favorite, played }

    /// A committed user-data mutation, broadcast to every subscriber on success. `userData`
    /// is the server's fresh copy for `itemID`; `operation` is which action produced it.
    ///
    /// SERIES CASCADE: marking a *series* played cascades server-side to all its episodes,
    /// but this event still carries only the series `ItemID` + its own `UserItemData` — the
    /// service does NOT fan out a per-episode event. A subscriber holding episodes of that
    /// series must treat a series-level change as "my episodes are now stale, refetch"; it
    /// cannot learn each episode's new flag from this event. Subscribers can now key this off
    /// `operation == .played` on the series id, rather than diffing a locally-cached flag.
    struct Change: Sendable {
        let itemID: ItemID
        /// Private: an operation's response may omit the OTHER operation's fields (see `merge`
        /// below), so a raw read outside this type risks adopting a DTO-boundary default as if
        /// it were real state. Go through `merged(into:)`, or `unfavorited` for the one
        /// legitimate raw read.
        private let userData: UserItemData
        let operation: Operation

        init(itemID: ItemID, userData: UserItemData, operation: Operation) {
            self.itemID = itemID
            self.userData = userData
            self.operation = operation
        }

        /// Convenience for broadcast subscribers: merges this change's payload into `existing`
        /// via the operation-scoped rule below — never adopt `userData` directly.
        func merged(into existing: UserItemData) -> UserItemData {
            UserDataActions.merge(operation, payload: userData, into: existing)
        }

        /// True for a favorite-operation change reporting the item is no longer a favorite —
        /// what a Favorites-scope grid needs to decide whether to drop the row outright (a
        /// merge doesn't apply there: the row is leaving, not patching). Gated on
        /// `operation == .favorite` for the same DTO-boundary reason `merge` documents: a
        /// played-operation payload's `isFavorite` is an absent-field default, not real state,
        /// so it must never read as an unfavorite.
        var unfavorited: Bool { operation == .favorite && !userData.isFavorite }
    }

    // MARK: - Operation-scoped merge

    /// A single canonical merge every patch site must go through instead of adopting a
    /// `Change`'s full `userData`. Server responses for one operation may omit the other
    /// operation's fields — `UserItemDataDto.toUserItemData()` maps an absent field to
    /// false/0 at the DTO boundary — so a played-operation response can carry
    /// `isFavorite: false` for an item that IS favorited, and symmetrically a
    /// favorite-operation response's `played`/`playbackPositionTicks`/`playCount` can read as
    /// unwatched/zero for an item with real progress. Patching in the full payload would
    /// silently corrupt whichever field the operation didn't touch (unfavoriting a favorited
    /// item on watch, or zeroing resume position on a favorite toggle). Merging keeps that
    /// server default-filling irrelevant: only the field(s) the operation actually owns move.
    static func merge(_ operation: Operation, payload: UserItemData, into existing: UserItemData) -> UserItemData {
        switch operation {
        case .favorite:
            return existing.withFavorite(payload.isFavorite)
        case .played:
            return existing.withPlayed(from: payload)
        }
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
    /// retain of the subscriber here. Most callers want `subscribe(_:)` instead, which owns the
    /// iterating `Task` for you; use `changes()` directly only when you need the raw stream
    /// (e.g. driving a `for await` from an existing loop, as tests do).
    func changes() -> AsyncStream<Change> {
        let id = UUID()
        // Unbounded buffer: a subscriber that doesn't drain promptly (its own `for await`
        // Task) accumulates every Change it misses rather than dropping them.
        let (stream, continuation) = AsyncStream<Change>.makeStream()
        subscribers[id] = continuation
        continuation.onTermination = { _ in
            // onTermination runs off the actor — hop back on to drop the entry.
            Task { @MainActor [weak self] in self?.subscribers[id] = nil }
        }
        return stream
    }

    /// Subscribes to `changes()` and forwards each `Change` to `handler`, replacing the
    /// five-line hand-rolled `Task { for await ... }` every subscriber used to write. Ownership
    /// is the returned `Task`'s: the caller stores it and cancels it when it dies (the same
    /// contract `changes()` documents) — this does not manage the subscriber's lifetime for it.
    /// `handler` should close over its subscriber `weak` (typically `[weak self] change in ...`)
    /// so the subscription itself never keeps the subscriber alive.
    @discardableResult
    func subscribe(_ handler: @escaping @MainActor (Change) async -> Void) -> Task<Void, Never> {
        let stream = changes()
        return Task {
            for await change in stream {
                await handler(change)
            }
        }
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
            broadcast(Change(itemID: itemID, userData: userData, operation: operation))
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
