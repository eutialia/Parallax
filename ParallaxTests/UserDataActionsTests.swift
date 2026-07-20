import Testing
import Foundation
import ParallaxCore
@testable import Parallax

/// Covers `UserDataActions`' two load-bearing contracts: the per-(item, op) in-flight guard
/// coalesces overlapping writes, and a change event is broadcast on success only.
@MainActor
@Suite("UserDataActions")
struct UserDataActionsTests {
    nonisolated private static func data(favorite: Bool, played: Bool = false) -> UserItemData {
        UserItemData(played: played, playbackPositionTicks: 0, playCount: 0, isFavorite: favorite)
    }

    /// A writer that parks its first `setFavorite` on a gate until the test releases it, and
    /// signals when it has entered — so a second toggle can be issued while the first is
    /// provably still in flight (the only way to exercise the guard deterministically).
    private final class GatedWriter: UserDataWriting, @unchecked Sendable {
        let userData: UserItemData
        private let lock = NSLock()
        private var release: CheckedContinuation<Void, Never>?
        private var onStarted: (@Sendable () -> Void)?
        private(set) var favoriteCallCount = 0

        init(userData: UserItemData, onStarted: @escaping @Sendable () -> Void) {
            self.userData = userData
            self.onStarted = onStarted
        }

        func setFavorite(itemID: ItemID, isFavorite: Bool) async throws -> UserItemData {
            lock.lock()
            favoriteCallCount += 1
            let started = onStarted
            onStarted = nil
            lock.unlock()
            started?()
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                lock.lock(); release = continuation; lock.unlock()
            }
            return userData
        }

        func setPlayed(itemID: ItemID, isPlayed: Bool) async throws -> UserItemData { userData }

        func releaseGate() {
            lock.lock(); let continuation = release; release = nil; lock.unlock()
            continuation?.resume()
        }
    }

    private struct Boom: Error {}

    @Test("concurrent double-toggle on the same item coalesces via the in-flight guard")
    func concurrentDoubleToggleCoalesces() async {
        let service = UserDataActions()
        let (startedStream, startedCont) = AsyncStream<Void>.makeStream()
        let writer = GatedWriter(userData: Self.data(favorite: true)) {
            startedCont.yield(); startedCont.finish()
        }
        let itemID = ItemID(rawValue: "movie-1")

        // First toggle parks inside the writer, holding the guard.
        let first = Task { await service.toggleFavorite(itemID: itemID, currentlyFavorite: false, via: writer) }
        var startedIterator = startedStream.makeAsyncIterator()
        _ = await startedIterator.next()

        // Second toggle, issued while the first is provably in flight, must skip.
        let secondOutcome = await service.toggleFavorite(itemID: itemID, currentlyFavorite: false, via: writer)
        writer.releaseGate()
        let firstOutcome = await first.value

        guard case .skipped = secondOutcome else {
            Issue.record("expected the coalesced toggle to be .skipped, got \(secondOutcome)")
            return
        }
        guard case .success = firstOutcome else {
            Issue.record("expected the in-flight toggle to succeed, got \(firstOutcome)")
            return
        }
        #expect(writer.favoriteCallCount == 1)
    }

    @Test("success broadcasts exactly one change carrying the repository's fresh UserItemData")
    func successBroadcastsOneEvent() async {
        let service = UserDataActions()
        let fresh = Self.data(favorite: true)
        let writer = StubUserDataWriter(favorite: .success(fresh))
        let itemID = ItemID(rawValue: "movie-2")

        var events = service.changes().makeAsyncIterator()
        let outcome = await service.toggleFavorite(itemID: itemID, currentlyFavorite: false, via: writer)

        guard case .success(let returned) = outcome else {
            Issue.record("expected .success, got \(outcome)")
            return
        }
        #expect(returned == fresh)

        let event = await events.next()
        #expect(event?.itemID == itemID)
        // `Change.userData` is private (only `merged(into:)`/`unfavorited` may read it) — merge
        // into the field the OTHER operation would've defaulted to zero/false, so the result
        // equals `fresh` only if the broadcast actually carried it.
        #expect(event?.merged(into: Self.data(favorite: false)) == fresh)
        #expect(event?.operation == .favorite)
    }

    @Test("a played toggle broadcasts a change tagged .played")
    func playedToggleBroadcastsPlayedOperation() async {
        let service = UserDataActions()
        let fresh = Self.data(favorite: false, played: true)
        let writer = StubUserDataWriter(favorite: .success(Self.data(favorite: false)), played: .success(fresh))
        let itemID = ItemID(rawValue: "movie-played")

        var events = service.changes().makeAsyncIterator()
        let outcome = await service.togglePlayed(itemID: itemID, currentlyPlayed: false, via: writer)

        guard case .success(let returned) = outcome else {
            Issue.record("expected .success, got \(outcome)")
            return
        }
        #expect(returned == fresh)

        let event = await events.next()
        #expect(event?.itemID == itemID)
        #expect(event?.operation == .played)
    }

    // MARK: - Operation-scoped merge

    /// A played-operation `Change` whose payload has `isFavorite: false` (the DTO boundary's
    /// absent-field default — Jellyfin's played response doesn't carry favorite state) must
    /// NOT unfavorite an item that's actually favorited. Only the played-derived fields move.
    @Test("a played-operation change merges in played fields but keeps the existing favorite flag")
    func playedChangeKeepsExistingFavorite() {
        let existing = Self.data(favorite: true, played: false)
        let payload = UserItemData(played: true, playbackPositionTicks: 0, playCount: 1, isFavorite: false)
        let change = UserDataActions.Change(itemID: ItemID(rawValue: "movie-3"), userData: payload, operation: .played)

        let merged = change.merged(into: existing)

        #expect(merged.isFavorite == true)
        #expect(merged.played == true)
        #expect(merged.playCount == 1)
    }

    /// Symmetric case: a favorite-operation `Change` whose payload has zeroed played/position
    /// (the DTO boundary's absent-field default for a favorite-only response) must NOT reset
    /// an item's watch progress. Only `isFavorite` moves.
    @Test("a favorite-operation change merges in the favorite flag but keeps existing played fields")
    func favoriteChangeKeepsExistingPlayedFields() {
        let existing = UserItemData(played: false, playbackPositionTicks: 12_345, playCount: 0, isFavorite: false)
        let payload = UserItemData(played: false, playbackPositionTicks: 0, playCount: 0, isFavorite: true)
        let change = UserDataActions.Change(itemID: ItemID(rawValue: "movie-4"), userData: payload, operation: .favorite)

        let merged = change.merged(into: existing)

        #expect(merged.isFavorite == true)
        #expect(merged.played == false)
        #expect(merged.playbackPositionTicks == 12_345)
    }

    @Test("failure broadcasts nothing and surfaces the error")
    func failureBroadcastsNothing() async {
        let service = UserDataActions()
        let fresh = Self.data(favorite: true)
        let writer = StubUserDataWriter(favorite: .failure(Boom()))
        let failID = ItemID(rawValue: "movie-fail")
        let okID = ItemID(rawValue: "movie-ok")

        var events = service.changes().makeAsyncIterator()
        let failOutcome = await service.toggleFavorite(itemID: failID, currentlyFavorite: false, via: writer)
        guard case .failure = failOutcome else {
            Issue.record("expected .failure, got \(failOutcome)")
            return
        }

        // A subsequent success on a DIFFERENT item: if the failed toggle had emitted, the
        // first buffered event would carry `failID`. Seeing `okID` first proves it did not.
        writer.favoriteResult = .success(fresh)
        _ = await service.toggleFavorite(itemID: okID, currentlyFavorite: false, via: writer)

        let event = await events.next()
        #expect(event?.itemID == okID)
    }
}
