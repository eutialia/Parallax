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
    public nonisolated let state: AsyncStream<PlaybackBeat>

    /// The session `load()` last opened, stamped onto every `push`. Mirrors both real engines:
    /// a fake is reloadable in place too, and a test that reloads it gets the same boundary the
    /// app relies on. `Mutex`-free because it is only written from `load()` and read from
    /// `push`, both on the generic executor in every existing suite; `nonisolated(unsafe)` is
    /// the same bargain the rest of this double's knobs make.
    public nonisolated(unsafe) private(set) var session: PlaybackSessionID = .none

    private struct RecordedState {
        var loadedAssets: [PlayableAsset] = []
        var calls: [String] = []
        var selectedAudioTrackID: TrackID? = nil
        var selectedSubtitleTrackID: TrackID? = nil
        var isPlayingNow = false
    }
    private let recordedState = Mutex(RecordedState())

    public var loadedAssets: [PlayableAsset] { recordedState.withLock { $0.loadedAssets } }
    public var calls: [String] { recordedState.withLock { $0.calls } }
    public var selectedAudioTrackID: TrackID? { recordedState.withLock { $0.selectedAudioTrackID } }
    public var selectedSubtitleTrackID: TrackID? { recordedState.withLock { $0.selectedSubtitleTrackID } }
    /// The engine's transport as STATE, not as the tail of `calls`. `calls` answers "which
    /// commands were issued, in which order"; this answers "where did the transport end up",
    /// which is the invariant a caller that commands the engine from several places actually
    /// owes (`engine.isPlayingNow == vm.desiredPlaying` at quiescence). A test that asserts on
    /// the last logged string instead is order-sensitive to whichever unstructured task happened
    /// to finish last.
    public var isPlayingNow: Bool { recordedState.withLock { $0.isPlayingNow } }

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

    private let continuation: AsyncStream<PlaybackBeat>.Continuation
    /// The hand-off ledger `settle()` reads — see `DrainBarrier`.
    private let barrier: DrainBarrier
    /// Parks `seek(to:)` on demand. See `holdSeeks()`.
    private let seekGate = ParkingGate()
    /// Parks state delivery on demand, with the element already in hand. See `holdBeats()`.
    private let beatGate: ParkingGate
    /// Parks `endAudio()` on demand. See `holdEndAudio()`.
    private let endAudioGate = ParkingGate()
    /// Parks `teardown()` on demand. See `holdTeardown()`.
    private let teardownGate = ParkingGate()

    public init(id: PlaybackEngineID, capabilities: PlaybackEngineCapabilities) {
        self.id = id
        self.capabilities = capabilities
        // Two-layer stream. The inner buffered stream keeps the ORIGINAL semantics
        // (`push` never blocks, states queue in order, `finish()` still drains what's
        // already queued, a cancelled consumer ends its loop). The outer `unfolding`
        // stream wraps it purely to expose the one thing a continuation-backed stream
        // can't: the moment the consumer asks for the NEXT element — which is exactly
        // the moment its `for await` body finished processing the previous one.
        let (buffered, cont) = AsyncStream<PlaybackBeat>.makeStream()
        let barrier = DrainBarrier()
        let source = BufferedSource(buffered)
        let beatGate = ParkingGate()
        self.beatGate = beatGate
        self.continuation = cont
        self.barrier = barrier
        self.state = AsyncStream(unfolding: {
            // Re-entered ⇒ the consumer's loop body for every delivered state returned.
            barrier.noteConsumerTurn()
            guard let next = await source.next() else { return nil }
            // The gate sits BETWEEN the pull and the delivery on purpose: that is the
            // window a real beat spends mid-hop to the MainActor, which is the only place
            // a replaced engine's state can still reach a consumer. See `holdBeats()`.
            await beatGate.park()
            barrier.noteDelivery()
            return next
        })
    }

    /// Push a state into the stream immediately, stamped with the current session.
    public func push(_ state: PlaybackState) {
        push(state, from: session)
    }

    /// Push a state stamped with an ARBITRARY session — the superseded-media beat a real engine
    /// drops at its own yield funnel, delivered here so the app side can be held to the same
    /// rule. A fake cannot reproduce the engine-internal race, so the stamp is handed over
    /// directly instead of being raced for.
    public func push(_ state: PlaybackState, from session: PlaybackSessionID) {
        // A push after the stream finished is dropped by the stream, so it must not be
        // counted either — otherwise it would be a debt `settle()` could never clear.
        guard barrier.notePush() else { return }
        continuation.yield(PlaybackBeat(session: session, state: state))
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

    /// Opens a new session like both real engines, so a reload's incoming beats are
    /// distinguishable from the outgoing ones a test left in flight.
    @discardableResult
    public func load(_ asset: PlayableAsset) async throws -> PlaybackSessionID {
        recordedState.withLock {
            $0.loadedAssets.append(asset)
            $0.calls.append("load")
        }
        if let loadError { throw loadError }
        session = session.next()
        return session
    }

    public func play() async {
        recordedState.withLock {
            $0.calls.append("play")
            $0.isPlayingNow = true
        }
    }

    public func pause() async {
        recordedState.withLock {
            $0.calls.append("pause")
            $0.isPlayingNow = false
        }
    }

    /// Recorded distinctly from "pause" so tests can tell a resumable silence from a
    /// transport pause — the two diverge on real engines (VLC mutes the audio output).
    public func silence() async { recordedState.withLock { $0.calls.append("silence") } }

    /// Recorded distinctly from "silence" too: this is the TERMINAL exit cut (VLC stops
    /// the player outright), and the exit tests assert exactly which of the two a path took.
    public func endAudio() async {
        recordedState.withLock {
            $0.calls.append("endAudio")
            // The terminal cut stops the player outright, so the transport is down with it.
            $0.isPlayingNow = false
        }
        await endAudioGate.park()
    }

    public func seek(to time: CMTime) async {
        let seconds = CMTimeGetSeconds(time)
        let formatted = String(format: "%.1f", seconds)
        recordedState.withLock { $0.calls.append("seek(\(formatted))") }
        await seekGate.park()
    }

    // MARK: - Gates

    /// Park every subsequent `seek(to:)` at its suspension point (after recording the call)
    /// until `releaseSeeks()`. The only way to hold a caller INSIDE `await engine.seek(...)`
    /// and run other MainActor work in that window, which is what an interleave test of a
    /// synchronous fence landing mid-seek needs. Off by default; no other path is affected.
    public func holdSeeks() { seekGate.hold() }

    /// True while at least one `seek(to:)` is parked on the gate. `waitUntil`-friendly proof
    /// that the caller really is suspended, so the interleaving under test is not a guess.
    public var hasParkedSeek: Bool { seekGate.hasParked }

    /// Lift the gate and resume every parked `seek(to:)`. Later seeks pass straight through.
    public func releaseSeeks() { seekGate.release() }

    /// Park state DELIVERY with the element already pulled from the stream — the beat is in
    /// the consumer's hands but its handler has not run. The window a replaced engine's last
    /// beat lives in: cancelling a subscription cannot recall a state already in flight, so
    /// this is what proves the consumer drops it on identity rather than on luck.
    public func holdBeats() { beatGate.hold() }

    /// True while a beat is parked between the pull and the delivery.
    public var hasParkedBeat: Bool { beatGate.hasParked }

    /// Number of states handed to the consumer. Unlike `settle()` this counts DELIVERY, not
    /// processing, so it is the barrier that still works for a subscription the view model
    /// has already cancelled — a cancelled `for await` never comes back for another element,
    /// so its processed count can never advance again.
    public var deliveredBeats: Int { barrier.deliveredCount() }

    /// Lift the beat gate and let every parked delivery through.
    public func releaseBeats() { beatGate.release() }

    /// Park `endAudio()` after it records the call — the awaited half of an engine swap.
    /// Holds the caller INSIDE `EngineSlot.swap`, which is the window a transport command
    /// or a beat can land in while the outgoing engine is still the live one.
    public func holdEndAudio() { endAudioGate.hold() }

    /// True while an `endAudio()` is parked on the gate.
    public var hasParkedEndAudio: Bool { endAudioGate.hasParked }

    /// Lift the audio-cut gate and let every parked `endAudio()` return.
    public func releaseEndAudio() { endAudioGate.release() }

    /// Park `teardown()` after it records the call and before it finishes the stream — a
    /// stand-in for VLC's multi-second teardown. What proves a retirement really runs off
    /// the swap's critical path, and that `drain()` really waits for it.
    public func holdTeardown() { teardownGate.hold() }

    /// True while a `teardown()` is parked on the gate.
    public var hasParkedTeardown: Bool { teardownGate.hasParked }

    /// Lift the teardown gate and let every parked `teardown()` finish.
    public func releaseTeardown() { teardownGate.release() }

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
        await teardownGate.park()
        finish()
    }

    public func captureFrame() async -> Data? {
        recordedState.withLock { $0.calls.append("captureFrame") }
        return captureFrameResult
    }
}

/// One hold-and-release gate, shared by every parking seam on the fake (`seek`, state
/// delivery, `teardown`). `park()` suspends its caller while the gate is up and returns
/// immediately when it isn't, so an unused gate costs nothing and no path branches on
/// which seam it is.
private final class ParkingGate: Sendable {
    private struct State {
        var isHeld = false
        var parked: [CheckedContinuation<Void, Never>] = []
    }

    private let state = Mutex(State())

    func hold() { state.withLock { $0.isHeld = true } }

    /// True while at least one caller is suspended here — `waitUntil`-friendly proof that
    /// the interleaving under test really happened, rather than a guess about scheduling.
    var hasParked: Bool { state.withLock { !$0.parked.isEmpty } }

    func release() {
        let due = state.withLock { s -> [CheckedContinuation<Void, Never>] in
            s.isHeld = false
            defer { s.parked = [] }
            return s.parked
        }
        for continuation in due { continuation.resume() }
    }

    func park() async {
        guard state.withLock({ $0.isHeld }) else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            // Re-read under the lock: `release()` can land between the check above and
            // here, and a continuation appended to a lifted gate would never be resumed.
            let resumeNow = state.withLock { s -> Bool in
                guard s.isHeld else { return true }
                s.parked.append(continuation)
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }
}

// MARK: — settle() machinery

/// Holds the inner buffered stream's iterator. `AsyncStream.Iterator` is a
/// non-`Sendable` mutable struct, so it needs a reference home to be pulled from the
/// outer stream's producer closure. Single-consumer by construction (one `for await`
/// over `FakePlaybackEngine.state`), which is what makes the unchecked conformance safe.
private final class BufferedSource: @unchecked Sendable {
    private var iterator: AsyncStream<PlaybackBeat>.Iterator

    init(_ stream: AsyncStream<PlaybackBeat>) {
        self.iterator = stream.makeAsyncIterator()
    }

    /// Nil on finish AND on consumer cancellation — `AsyncStream`'s own iterator
    /// handles both, so the outer stream inherits the original termination behavior.
    func next() async -> PlaybackBeat? {
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
    func deliveredCount() -> Int { ledger.withLock { $0.delivered } }

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
