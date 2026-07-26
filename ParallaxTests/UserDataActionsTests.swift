import Testing
import Foundation
import ParallaxCore
import ParallaxJellyfin
@testable import Parallax

/// One half of the operation-scoped merge rule. A named case rather than a tuple because Swift
/// Testing only destructures 2-tuples into parameters.
struct MergeCase: Sendable, CustomTestStringConvertible {
    let operation: UserDataActions.Operation
    let payload: UserItemData
    let existing: UserItemData
    let expected: UserItemData
    var testDescription: String { "\(operation)" }
}

/// Both payloads carry the DTO boundary's absent-field default for the OTHER operation
/// (`UserItemDataDto.toUserItemData()` maps absent → false/0): Jellyfin's played response doesn't
/// report favorite state, and its favorite response doesn't report progress. Adopting a payload
/// wholesale would unfavorite a favorited item on watch, or wipe a real resume position on a
/// favorite tap — so each case's `expected` keeps the other operation's fields from `existing`.
private let mergeCases: [MergeCase] = [
    MergeCase(
        operation: .played,
        payload: UserItemData(played: true, playbackPositionTicks: 0, playCount: 1, isFavorite: false),
        existing: UserItemData(played: false, playbackPositionTicks: 12_345, playCount: 0, isFavorite: true),
        expected: UserItemData(played: true, playbackPositionTicks: 0, playCount: 1, isFavorite: true)
    ),
    MergeCase(
        operation: .favorite,
        payload: UserItemData(played: false, playbackPositionTicks: 0, playCount: 0, isFavorite: true),
        existing: UserItemData(played: true, playbackPositionTicks: 12_345, playCount: 3, isFavorite: false),
        expected: UserItemData(played: true, playbackPositionTicks: 12_345, playCount: 3, isFavorite: true)
    ),
]

/// Covers `UserDataActions`' two load-bearing contracts: the per-(item, op) in-flight guard
/// coalesces overlapping writes, and a change event is broadcast on success only.
@MainActor
@Suite("UserDataActions")
struct UserDataActionsTests {
    /// These tests exercise one server; the (source, itemID) key is covered by SourcedItemMergeTests.

    nonisolated private static func data(favorite: Bool, played: Bool = false) -> UserItemData {
        UserItemData(played: played, playbackPositionTicks: 0, playCount: 0, isFavorite: favorite)
    }

    /// Records EVERY `Change` the broadcast emits, not just the first. "Exactly one event" is half an
    /// assertion when a test only reads element 0: a service that emitted twice (optimistically, then
    /// again on the response) would pass while making every subscriber patch twice — and on the
    /// Favorites wall a duplicate `unfavorited` change removes a row that has already gone.
    @MainActor
    private final class ChangeLog {
        fileprivate var received: [UserDataActions.Change] = []
        private var task: Task<Void, Never>?

        /// Subscribes immediately, so this must be built BEFORE the toggle under test.
        static func watching(_ service: UserDataActions) -> ChangeLog {
            let log = ChangeLog()
            log.task = service.subscribe { [weak log] change in
                guard let log else { return }
                log.received.append(change)
            }
            return log
        }

        /// Everything the broadcast queued, once the subscriber's `for await` has drained it. The
        /// broadcast yields synchronously inside `perform`, so by the time a toggle has returned any
        /// event it produced is already buffered — yielding is enough, no wall-clock sleep.
        func settled() async -> [UserDataActions.Change] {
            await waitUntil { self.received.isEmpty == false }
            // Keep yielding past the first element so a SECOND queued event lands before we count.
            for _ in 0..<100 { await Task.yield() }
            task?.cancel()
            return received
        }
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
        let first = Task { await service.toggleFavorite(itemID: itemID, source: testJellyfinSource, currentlyFavorite: false, via: writer) }
        var startedIterator = startedStream.makeAsyncIterator()
        _ = await startedIterator.next()

        // Second toggle, issued while the first is provably in flight, must skip.
        let secondOutcome = await service.toggleFavorite(itemID: itemID, source: testJellyfinSource, currentlyFavorite: false, via: writer)
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

    @Test("a favorite success broadcasts exactly ONE change, carrying the fresh UserItemData and the item's source")
    func successBroadcastsOneEvent() async throws {
        let service = UserDataActions()
        let fresh = Self.data(favorite: true)
        let writer = StubUserDataWriter(favorite: .success(fresh))
        let itemID = ItemID(rawValue: "movie-2")

        let log = ChangeLog.watching(service)
        let outcome = await service.toggleFavorite(itemID: itemID, source: testJellyfinSource, currentlyFavorite: false, via: writer)

        guard case .success(let returned) = outcome else {
            Issue.record("expected .success, got \(outcome)")
            return
        }
        #expect(returned == fresh)

        let events = await log.settled()
        #expect(events.count == 1)
        let event = try #require(events.first)
        #expect(event.itemID == itemID)
        // Every consumer matches on (source, itemID) — an untagged/mis-tagged source patches the same
        // item id on the WRONG server (the mirrored-GUID case `SourcedItemMergeTests` pins).
        #expect(event.source == testJellyfinSource)
        // `Change.userData` is private (only `merged(into:)`/`unfavorited` may read it) — merge
        // into the field the OTHER operation would've defaulted to zero/false, so the result
        // equals `fresh` only if the broadcast actually carried it.
        #expect(event.merged(into: Self.data(favorite: false)) == fresh)
        #expect(event.operation == .favorite)
    }

    @Test("a played success broadcasts exactly ONE change tagged .played, carrying its fresh payload and source")
    func playedToggleBroadcastsPlayedOperation() async throws {
        let service = UserDataActions()
        let fresh = Self.data(favorite: false, played: true)
        let writer = StubUserDataWriter(favorite: .success(Self.data(favorite: false)), played: .success(fresh))
        let itemID = ItemID(rawValue: "movie-played")

        let log = ChangeLog.watching(service)
        let outcome = await service.togglePlayed(itemID: itemID, source: testJellyfinSource, currentlyPlayed: false, via: writer)

        guard case .success(let returned) = outcome else {
            Issue.record("expected .success, got \(outcome)")
            return
        }
        #expect(returned == fresh)

        let events = await log.settled()
        #expect(events.count == 1)
        let event = try #require(events.first)
        #expect(event.itemID == itemID)
        #expect(event.source == testJellyfinSource)
        #expect(event.operation == .played)
        // The payload assertion its favorite twin always had: merging into a value whose played
        // fields are all false/0 leaves only `isFavorite` coming from `existing`, so this equals
        // `fresh` only if the broadcast actually carried the writer's response.
        #expect(event.merged(into: Self.data(favorite: false)) == fresh)
    }

    // MARK: - Operation-scoped merge

    @Test(
        "an operation-scoped change moves only its own fields, never the other operation's",
        arguments: mergeCases
    )
    func mergeIsScopedToTheOperation(_ testCase: MergeCase) {
        let change = UserDataActions.Change(
            itemID: ItemID(rawValue: "movie-merge"),
            source: testJellyfinSource,
            userData: testCase.payload,
            operation: testCase.operation
        )

        #expect(change.merged(into: testCase.existing) == testCase.expected)
    }

    @Test("failure broadcasts nothing and surfaces the error")
    func failureBroadcastsNothing() async throws {
        let service = UserDataActions()
        let fresh = Self.data(favorite: true)
        let writer = StubUserDataWriter(favorite: .failure(Boom()))
        let failID = ItemID(rawValue: "movie-fail")
        let okID = ItemID(rawValue: "movie-ok")

        let log = ChangeLog.watching(service)
        let failOutcome = await service.toggleFavorite(itemID: failID, source: testJellyfinSource, currentlyFavorite: false, via: writer)
        guard case .failure = failOutcome else {
            Issue.record("expected .failure, got \(failOutcome)")
            return
        }

        // A subsequent success on a DIFFERENT item: the log must hold exactly that one event, so a
        // stray emission from the failed toggle can't hide behind "the first element looks right".
        writer.favoriteResult = .success(fresh)
        _ = await service.toggleFavorite(itemID: okID, source: testJellyfinSource, currentlyFavorite: false, via: writer)

        let events = await log.settled()
        #expect(events.count == 1)
        #expect(events.first?.itemID == okID)
    }
}
