import Foundation
import CoreMedia
import Synchronization
import ParallaxTestScaling
import ParallaxPlayback

// MARK: — PlaybackEngineCapabilities convenience stubs

extension PlaybackEngineCapabilities {
    /// AVKit preset: all capabilities enabled.
    public static let avKit = PlaybackEngineCapabilities(
        supportsPiP: true,
        supportsVideoAirPlay: true,
        supportsNowPlayingIntegration: true
    )

    /// VLC preset: Now Playing only. MobileVLCKit ships no Picture-in-Picture API and
    /// renders offscreen, so neither PiP nor video AirPlay is available — mirrors
    /// `VLCKitEngine.capabilities`.
    public static let vlcKit = PlaybackEngineCapabilities(
        supportsPiP: false,
        supportsVideoAirPlay: false,
        supportsNowPlayingIntegration: true
    )
}

// MARK: — FakePlaybackEngine

/// Deterministic `PlaybackEngine` test double.
///
/// - Push states via `push(_:)` — emitted to the `state` stream in order.
/// - `await settle()` after pushing to wait for the consumer to finish processing
///   every pushed state — the deterministic replacement for a `Task.sleep` barrier.
/// - Inspect recorded calls via `calls`, `loadedAssets`, `selectedAudioTrackID`, etc.
/// - `teardown()` finishes the stream so async `for await` loops terminate.
/// - Call `finish()` to close the stream without recording "teardown".
///
/// Thread-safety: this is a test double, called from the generic executor (the
/// protocol's `async` methods) while `@MainActor` tests poll its recording fields —
/// two different isolation domains touching the same state. `calls`, `loadedAssets`,
/// `selectedAudioTrackID`, and `selectedSubtitleTrackID` are guarded by a `Mutex`
/// (`recordedState`) so a real reactive-fallback-style engine swap (a background hop
/// writing while the test reads) can't race; the public properties below are
/// computed reads through the lock, so the call-site surface is unchanged. Reads are
/// safe from any context; PROVING an ordering (e.g. "the retry engine's `play` landed
/// after the teardown") still needs `settle()`/`waitUntil` — the lock only rules out
/// a torn read, it doesn't sequence calls for you.
public final class FakePlaybackEngine: PlaybackEngine {

    public nonisolated let id: PlaybackEngineID
    public nonisolated let capabilities: PlaybackEngineCapabilities
    public nonisolated let state: AsyncStream<PlaybackState>

    private struct RecordedState {
        var loadedAssets: [PlayableAsset] = []
        var calls: [String] = []
        var selectedAudioTrackID: TrackID? = nil
        var selectedSubtitleTrackID: TrackID? = nil
    }
    private let recordedState = Mutex(RecordedState())

    public var loadedAssets: [PlayableAsset] { recordedState.withLock { $0.loadedAssets } }
    public var calls: [String] { recordedState.withLock { $0.calls } }
    public var selectedAudioTrackID: TrackID? { recordedState.withLock { $0.selectedAudioTrackID } }
    public var selectedSubtitleTrackID: TrackID? { recordedState.withLock { $0.selectedSubtitleTrackID } }

    /// Set to make every `load` throw after recording — a failed stream load.
    public nonisolated(unsafe) var loadError: Error? = nil
    /// Drives `isBuffered(at:)`. `nil` (default) → always buffered, matching the
    /// protocol default so seek-path tests are unaffected. Set a range to make a
    /// target outside it read as out-of-buffer (→ the transcode re-anchor path).
    public nonisolated(unsafe) var bufferedRange: ClosedRange<Double>? = nil

    /// Returned by `captureFrame()`. `nil` (default) matches the protocol default; a test that
    /// wants to prove a captured frame flows through to a store sets this before pushing the
    /// beat that schedules the capture.
    public nonisolated(unsafe) var captureFrameResult: Data? = nil
    /// Overrides `captureFramePerformsIO`. Defaults to the protocol's own default (`true`) so a
    /// test that doesn't care about the WAN-skip behavior isn't surprised by a fake-specific one.
    public nonisolated(unsafe) var captureFramePerformsIO = true

    private let continuation: AsyncStream<PlaybackState>.Continuation
    /// The hand-off ledger `settle()` reads — see `DrainBarrier`.
    private let barrier: DrainBarrier

    public init(id: PlaybackEngineID, capabilities: PlaybackEngineCapabilities) {
        self.id = id
        self.capabilities = capabilities
        // Two-layer stream. The inner buffered stream keeps the ORIGINAL semantics
        // (`push` never blocks, states queue in order, `finish()` still drains what's
        // already queued, a cancelled consumer ends its loop). The outer `unfolding`
        // stream wraps it purely to expose the one thing a continuation-backed stream
        // can't: the moment the consumer asks for the NEXT element — which is exactly
        // the moment its `for await` body finished processing the previous one.
        let (buffered, cont) = AsyncStream<PlaybackState>.makeStream()
        let barrier = DrainBarrier()
        let source = BufferedSource(buffered)
        self.continuation = cont
        self.barrier = barrier
        self.state = AsyncStream(unfolding: {
            // Re-entered ⇒ the consumer's loop body for every delivered state returned.
            barrier.noteConsumerTurn()
            guard let next = await source.next() else { return nil }
            barrier.noteDelivery()
            return next
        })
    }

    /// Push a state into the stream immediately.
    public func push(_ state: PlaybackState) {
        // A push after the stream finished is dropped by the stream, so it must not be
        // counted either — otherwise it would be a debt `settle()` could never clear.
        guard barrier.notePush() else { return }
        continuation.yield(state)
    }

    /// Finish the stream without recording a "teardown" call.
    public func finish() {
        barrier.noteFinish()
        continuation.finish()
    }

    /// Thrown by `settle()` when the consumer never drained — a real deadlock/bug,
    /// surfaced as a test failure instead of a hung run.
    public struct SettleTimeout: Error, CustomStringConvertible {
        public let pushed: Int
        public let processed: Int
        public var description: String {
            "FakePlaybackEngine.settle() timed out: \(processed) of \(pushed) pushed states processed"
        }
    }

    /// Suspends until every state pushed **so far** has been delivered to the
    /// `state` consumer AND that consumer's `for await` body has run to completion
    /// for each of them.
    ///
    /// Deterministic, not a shorter sleep: an `AsyncStream` iterator only re-enters
    /// the outer stream's producer once the loop body for the previous element has
    /// returned, so "the consumer pulled element n+1" *is* the proof that element n
    /// was fully processed. `settle()` waits for that pull count to reach the push
    /// count — no wall-clock guessing. Note it covers the consumer's own turn only;
    /// work the consumer detaches into a separate `Task` needs its own barrier.
    ///
    /// `timeout` is a safety net for the pathological "nobody will pull again" cases
    /// (nothing subscribed, the consumer parked forever inside its body, or a consumer
    /// that `break`s out of its loop). The happy path still needs the consumer task
    /// SCHEDULED, which is the runtime's call, not ours — a loaded CI runner was
    /// measured taking 33s to run a just-spawned consumer, tripping the unscaled 5s
    /// net — so the value is `CITimeScale`d like every anti-hang ceiling. The
    /// deliberately-tiny timeouts in the negative-path tests scale too and still fire.
    public func settle(timeout: Duration = .seconds(5)) async throws {
        let timeout = CITimeScale.seconds(timeout / .seconds(1))
        let target = barrier.pushCount()
        guard try await barrier.waitForDrain(upTo: target, timeout: timeout) else {
            throw SettleTimeout(pushed: target, processed: barrier.processedCount())
        }
    }

    public func load(_ asset: PlayableAsset) async throws {
        recordedState.withLock {
            $0.loadedAssets.append(asset)
            $0.calls.append("load")
        }
        if let loadError { throw loadError }
    }

    public func play() async { recordedState.withLock { $0.calls.append("play") } }

    public func pause() async { recordedState.withLock { $0.calls.append("pause") } }

    public func seek(to time: CMTime) async {
        let seconds = CMTimeGetSeconds(time)
        let formatted = String(format: "%.1f", seconds)
        recordedState.withLock { $0.calls.append("seek(\(formatted))") }
    }

    public func isBuffered(at time: CMTime) async -> Bool {
        guard let bufferedRange else { return true }
        return bufferedRange.contains(CMTimeGetSeconds(time))
    }

    public func setAudioTrack(_ track: AudioTrack) async {
        recordedState.withLock {
            $0.selectedAudioTrackID = track.id
            $0.calls.append("setAudioTrack(\(track.id))")
        }
    }

    public func setSubtitleTrack(_ track: SubtitleTrack?) async {
        recordedState.withLock {
            $0.selectedSubtitleTrackID = track?.id
            $0.calls.append(track.map { "setSubtitleTrack(\($0.id))" } ?? "setSubtitleTrack(nil)")
        }
    }

    public func setSubtitleDelay(milliseconds: Int) async {
        recordedState.withLock { $0.calls.append("setSubtitleDelay(\(milliseconds))") }
    }

    public func teardown() async {
        recordedState.withLock { $0.calls.append("teardown") }
        finish()
    }

    public func captureFrame() async -> Data? {
        recordedState.withLock { $0.calls.append("captureFrame") }
        return captureFrameResult
    }
}

// MARK: — settle() machinery

/// Holds the inner buffered stream's iterator. `AsyncStream.Iterator` is a
/// non-`Sendable` mutable struct, so it needs a reference home to be pulled from the
/// outer stream's producer closure. Single-consumer by construction (one `for await`
/// over `FakePlaybackEngine.state`), which is what makes the unchecked conformance safe.
private final class BufferedSource: @unchecked Sendable {
    private var iterator: AsyncStream<PlaybackState>.Iterator

    init(_ stream: AsyncStream<PlaybackState>) {
        self.iterator = stream.makeAsyncIterator()
    }

    /// Nil on finish AND on consumer cancellation — `AsyncStream`'s own iterator
    /// handles both, so the outer stream inherits the original termination behavior.
    func next() async -> PlaybackState? {
        await iterator.next()
    }
}

/// The push/deliver/process ledger behind `FakePlaybackEngine.settle()`.
///
/// `processed` advances only when the consumer comes back for another element, so it
/// counts states whose handler RETURNED — never states merely handed over.
private final class DrainBarrier: Sendable {
    /// One `settle()` caller. Registered BEFORE its continuation exists so a
    /// cancellation (or a drain) landing in that window is recorded rather than lost:
    /// `continuation == nil` + `isCancelled` is resolved by whichever side arrives second.
    private struct Waiter {
        let target: Int
        var continuation: CheckedContinuation<Void, Never>?
        var isCancelled = false
    }

    private struct Ledger {
        var pushed = 0
        var delivered = 0
        var processed = 0
        var finished = false
        var nextWaiterID = 0
        var waiters: [Int: Waiter] = [:]
    }

    private let ledger = Mutex(Ledger())

    /// False once the stream is finished — the caller must then drop the push.
    func notePush() -> Bool {
        ledger.withLock { l in
            guard !l.finished else { return false }
            l.pushed += 1
            return true
        }
    }

    func noteFinish() {
        ledger.withLock { $0.finished = true }
    }

    func noteDelivery() {
        ledger.withLock { $0.delivered += 1 }
    }

    /// The consumer pulled again ⇒ everything delivered so far is processed.
    func noteConsumerTurn() {
        let due = ledger.withLock { l -> [CheckedContinuation<Void, Never>] in
            l.processed = l.delivered
            var resumable: [CheckedContinuation<Void, Never>] = []
            for (id, waiter) in l.waiters where waiter.target <= l.processed {
                // Removing an as-yet-continuation-less waiter is the signal its own
                // `withCheckedContinuation` body reads to resume immediately.
                l.waiters.removeValue(forKey: id)
                if let continuation = waiter.continuation { resumable.append(continuation) }
            }
            return resumable
        }
        for continuation in due { continuation.resume() }
    }

    func pushCount() -> Int { ledger.withLock { $0.pushed } }
    func processedCount() -> Int { ledger.withLock { $0.processed } }

    /// True once `processed >= target`; false if `timeout` elapsed first.
    func waitForDrain(upTo target: Int, timeout: Duration) async throws -> Bool {
        guard ledger.withLock({ $0.processed < target }) else { return true }
        return try await withThrowingTaskGroup(of: Bool.self) { group in
            group.addTask { await self.park(until: target); return true }
            group.addTask { try await Task.sleep(for: timeout); return false }
            // First child to finish wins; the loser is cancelled (the parked waiter
            // resumes through its cancellation handler, the sleeper just throws).
            let drained = try await group.next() ?? false
            group.cancelAll()
            return drained
        }
    }

    private func park(until target: Int) async {
        let id: Int? = ledger.withLock { l in
            guard l.processed < target else { return nil }
            l.nextWaiterID += 1
            l.waiters[l.nextWaiterID] = Waiter(target: target)
            return l.nextWaiterID
        }
        guard let id else { return }
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let resumeNow = ledger.withLock { l -> Bool in
                    // Gone ⇒ the drain already satisfied it. Cancelled ⇒ the handler
                    // below fired before the continuation existed. Either way: resume.
                    guard var waiter = l.waiters[id], !waiter.isCancelled else {
                        l.waiters.removeValue(forKey: id)
                        return true
                    }
                    waiter.continuation = continuation
                    l.waiters[id] = waiter
                    return false
                }
                if resumeNow { continuation.resume() }
            }
        } onCancel: {
            let continuation = ledger.withLock { l -> CheckedContinuation<Void, Never>? in
                guard var waiter = l.waiters[id] else { return nil }
                guard let continuation = waiter.continuation else {
                    waiter.isCancelled = true
                    l.waiters[id] = waiter
                    return nil
                }
                l.waiters.removeValue(forKey: id)
                return continuation
            }
            continuation?.resume()
        }
    }
}
