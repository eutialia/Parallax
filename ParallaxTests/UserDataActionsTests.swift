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

    /// A writer with canned, per-call results — no gate.
    private final class StubWriter: UserDataWriting, @unchecked Sendable {
        var favoriteResult: Result<UserItemData, Error>
        var playedResult: Result<UserItemData, Error>

        init(favorite: Result<UserItemData, Error>, played: Result<UserItemData, Error> = .success(data(favorite: false))) {
            self.favoriteResult = favorite
            self.playedResult = played
        }

        func setFavorite(itemID: ItemID, isFavorite: Bool) async throws -> UserItemData { try favoriteResult.get() }
        func setPlayed(itemID: ItemID, isPlayed: Bool) async throws -> UserItemData { try playedResult.get() }
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
        let writer = StubWriter(favorite: .success(fresh))
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
        #expect(event?.userData == fresh)
    }

    @Test("failure broadcasts nothing and surfaces the error")
    func failureBroadcastsNothing() async {
        let service = UserDataActions()
        let fresh = Self.data(favorite: true)
        let writer = StubWriter(favorite: .failure(Boom()))
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
