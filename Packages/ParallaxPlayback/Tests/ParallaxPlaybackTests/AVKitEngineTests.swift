import Foundation
import AVFoundation
import CoreMedia
import Testing
import ParallaxPlaybackTestSupport
@testable import ParallaxPlayback

@Suite("AVKitEngine")
@MainActor
struct AVKitEngineTests {

    @Test("Declares the AVKit id and all-true capabilities")
    func identityAndCapabilities() {
        let engine = AVKitEngine()
        #expect(engine.id == .avKit)
        #expect(engine.capabilities == PlaybackEngineCapabilities(
            supportsPiP: true, supportsVideoAirPlay: true, supportsNowPlayingIntegration: true
        ))
    }

    /// The app sets `AVPlayerViewController.player` through this seam, so the hosting
    /// property must vend the very instance the engine drives — not a fresh one.
    @Test("Conforms to AVPlayerHosting and vends the AVPlayer it drives")
    func hostsAnAVPlayer() {
        let engine = AVKitEngine()
        let hosting: any AVPlayerHosting = engine
        #expect(hosting.avPlayer === engine.avPlayer)
    }
}

/// The engine-agnostic half of the `PlaybackEngine` stream contract, run against both
/// concrete engines. Previously duplicated verbatim in `AVKitEngineTests` and
/// `VLCKitEngineTests`.
// `.timeLimit`: `teardownFinishesStream` awaits a terminal nil from a real engine's stream.
// Swift Testing applies no default timeout, so an engine that never finishes its continuation
// wedges the whole run instead of failing its own test.
@Suite("PlaybackEngine stream contract", .timeLimit(.minutes(1)))
@MainActor
struct PlaybackEngineStreamContractTests {

    enum EngineKind: String, CaseIterable, CustomTestStringConvertible {
        case avKit, vlcKit
        var testDescription: String { rawValue }

        @MainActor func make() -> any PlaybackEngine {
            switch self {
            case .avKit: AVKitEngine()
            case .vlcKit: VLCKitEngine()
            }
        }
    }

    @Test("the state stream is pre-seeded with .idle", arguments: EngineKind.allCases)
    func emitsIdleFirst(kind: EngineKind) async {
        let engine = kind.make()
        var iterator = engine.state.makeAsyncIterator()
        let first = await iterator.next()
        guard case .idle = first else {
            Issue.record("expected .idle, got \(String(describing: first))")
            return
        }
    }

    @Test("teardown finishes the state stream so consumers' for-await loops end",
          arguments: EngineKind.allCases)
    func teardownFinishesStream(kind: EngineKind) async {
        let engine = kind.make()
        var iterator = engine.state.makeAsyncIterator()
        _ = await iterator.next()          // drain the buffered .idle
        await engine.teardown()
        // Any further buffered beats are allowed; the stream MUST terminate.
        while let value = await iterator.next() {
            if case .idle = value { continue }
            break
        }
        let terminal = await iterator.next()
        #expect(terminal == nil)
    }

    @Test("the engine id matches the kind that built it", arguments: EngineKind.allCases)
    func reportsItsOwnID(kind: EngineKind) {
        let expected: PlaybackEngineID = kind == .avKit ? .avKit : .vlcKit
        #expect(kind.make().id == expected)
    }
}

/// `redactedTail` is the only thing that ever writes an HLS resource URI into a log,
/// and the api_key rides in that URI's query — so dropping the query is a security
/// contract, not cosmetics.
@Suite("AVKitEngine — HLS error-log redaction")
@MainActor
struct AVKitLogRedactionTests {

    @Test("keeps the trailing two path components and drops the query", arguments: [
        ("https://jf.example.com/Videos/abc/main.m3u8?api_key=SECRET", "abc/main.m3u8"),
        ("https://jf.example.com/Videos/abc/hls1/main/123.mp4?api_key=SECRET&x=1", "main/123.mp4"),
        ("https://jf.example.com/master.m3u8", "master.m3u8"),
    ])
    func redactsTail(uri: String, expected: String) {
        let tail = AVKitEngine.redactedTail(of: uri)
        #expect(tail == expected)
        #expect(tail?.contains("SECRET") == false)
        #expect(tail?.contains("?") == false)
    }

    @Test("returns nil when there is no path to report", arguments: [
        "https://jf.example.com",
        "https://jf.example.com/",
    ])
    func nilWithoutPath(uri: String) {
        #expect(AVKitEngine.redactedTail(of: uri) == nil)
    }
}

/// `PlayableAsset.engineSubtitlesDisabled` on the AVKit path. VLC has `:no-spu`;
/// AVFoundation has no equivalent, so the contract is enforced by deselecting the legible
/// group (once when the media selection groups load, once at `.ready` — AVPlayer applies
/// its own automatic selection between the two) and by refusing to select afterwards.
///
/// Driven against a real 3-second MP4 carrying two `mov_text` tracks: a fake could not
/// prove anything here, because the whole question is what AVFoundation does on its own.
// `.timeLimit`: every test here drains a real AVFoundation state stream until `.ready`. A
// simulator with a wedged mediaserverd (or a fixture that failed to copy) publishes neither
// beat, and `await iterator.next()` would suspend forever.
@Suite("AVKitEngine — assets that render their own subtitles", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct AVKitSubtitleSuppressionTests {

    private static var subtitledFixture: URL {
        get throws {
            try #require(
                Bundle.module.url(forResource: "subtitled", withExtension: "mp4", subdirectory: "Fixtures"),
                "subtitled.mp4 fixture missing from the test bundle"
            )
        }
    }

    /// Loads the fixture and returns the inventory the engine publishes with `.ready`.
    private func loadAndAwaitReady(_ engine: AVKitEngine, disabled: Bool) async throws -> TrackInventory {
        var iterator = engine.state.makeAsyncIterator()
        try await engine.load(.fixture(url: Self.subtitledFixture, engineSubtitlesDisabled: disabled))
        while let beat = await iterator.next() {
            if case .ready(_, let tracks) = beat { return tracks }
            if case .failed(let error) = beat { throw error }
        }
        Issue.record("the engine never reached .ready")
        return .empty
    }

    @Test("reaches .ready with a legible group present and nothing selected in it")
    func readyPublishesNoLegibleSelection() async throws {
        let engine = AVKitEngine()
        let tracks = try await loadAndAwaitReady(engine, disabled: true)
        let info = await engine.debugSnapshot()

        // Not a vacuous pass: the asset really does offer legible options.
        #expect(info.legibleOptions.isEmpty == false)
        #expect(info.selectedLegible == nil)
        #expect(tracks.selectedSubtitleID == nil)
        #expect(tracks.subtitles.isEmpty == false)
        await engine.teardown()
    }

    @Test("setSubtitleTrack is refused — the legible group stays empty")
    func setSubtitleTrackIsRefused() async throws {
        let engine = AVKitEngine()
        let tracks = try await loadAndAwaitReady(engine, disabled: true)

        let track = try #require(tracks.subtitles.first)
        await engine.setSubtitleTrack(track)

        #expect(await engine.debugSnapshot().selectedLegible == nil)
        await engine.teardown()
    }

    /// The invariant the app depends on: after the server-preference audio re-point
    /// (`PlayerViewModel.applyServerPreferredTracks`), nothing legible is selected.
    /// AVFoundation documents that automatic media selection criteria re-apply when a
    /// selection is made in ANOTHER group, which would resurrect the system-language
    /// subtitle the load- and ready-time deselects had cleared; the engine therefore
    /// deselects again after every audible selection.
    ///
    /// **Honest scope:** this is a LOCK, not a reproduction — measured against this local
    /// MP4 the re-application does not happen even with the criteria set below, so the test
    /// stays green with the post-audio deselect removed. It pins the observable contract;
    /// the deselect earns its keep on the HLS transcode path the fixture cannot reach.
    @Test("selecting an audio track leaves the legible group unselected")
    func audioSelectionDoesNotResurrectSubtitles() async throws {
        let engine = AVKitEngine()
        // Criteria stated rather than inherited: a simulator whose system language matches
        // neither `eng` nor `fra` would have nothing to re-apply in the first place.
        engine.avPlayer.setMediaSelectionCriteria(
            AVPlayerMediaSelectionCriteria(preferredLanguages: ["en"], preferredMediaCharacteristics: nil),
            forMediaCharacteristic: .legible
        )
        let tracks = try await loadAndAwaitReady(engine, disabled: true)
        let audio = try #require(tracks.audio.first)

        await engine.setAudioTrack(audio)

        let info = await engine.debugSnapshot()
        #expect(info.legibleOptions.isEmpty == false)   // not a vacuous pass
        #expect(info.selectedLegible == nil)
        await engine.teardown()
    }

    /// The control: the refusal above is the ASSET's intent talking, not a broken selector.
    @Test("an ordinary asset still selects, and can still be turned off")
    func ordinaryAssetSelectsNormally() async throws {
        let engine = AVKitEngine()
        let tracks = try await loadAndAwaitReady(engine, disabled: false)
        let track = try #require(tracks.subtitles.first)

        await engine.setSubtitleTrack(track)
        #expect(await engine.debugSnapshot().selectedLegible != nil)

        await engine.setSubtitleTrack(nil)
        #expect(await engine.debugSnapshot().selectedLegible == nil)
        await engine.teardown()
    }
}

/// The AVKit half of the seek-settle contract (`PlaybackState`). AVFoundation publishes the
/// transitional clock through the periodic observer and the `timeControlStatus` KVO with no
/// marker of its own, so a consumer could not tell "the player is at 00:12" from "the player
/// is on its way somewhere and 00:12 is where it happens to be". Driven against the real
/// 3-second fixture: the question is what AVFoundation does, which no fake can answer.
// `.timeLimit`: each test drains a real AVFoundation stream until `.ready`; a wedged
// mediaserverd would otherwise suspend forever.
@Suite("AVKitEngine — the seek-settle contract", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct AVKitSeekSettleTests {

    private static var fixture: URL {
        get throws {
            try #require(
                Bundle.module.url(forResource: "subtitled", withExtension: "mp4", subdirectory: "Fixtures"),
                "subtitled.mp4 fixture missing from the test bundle"
            )
        }
    }

    /// Loads the fixture and returns once the item is `.readyToPlay` (so `seek(to:)` reaches
    /// the real seek path rather than being queued against a not-yet-ready item).
    ///
    /// The iterator below is a SECOND consumer of `engine.state` — every caller then builds a
    /// `PositionBeatLog` over the same stream, and an `AsyncStream` has one buffer that its
    /// consumers race for. Safe only because this one is dead by then: it is a local, it stops
    /// at `.ready`, and it goes out of scope on return, so from the log's construction onward
    /// there is exactly one consumer. The ordering matters too — the log must be built AFTER
    /// this returns, which is what every caller does, or the two would split the beats.
    private func readyEngine() async throws -> AVKitEngine {
        let engine = AVKitEngine()
        var iterator = engine.state.makeAsyncIterator()
        try await engine.load(.fixture(url: Self.fixture))
        while let beat = await iterator.next() {
            if case .ready = beat { return engine }
            if case .failed(let error) = beat { throw error }
        }
        Issue.record("the engine never reached .ready")
        return engine
    }

    /// The out-of-buffer echo: a paused player fetches without ever entering
    /// `.waitingToPlayAtSpecifiedRate`, so the engine emits the fetch itself — at the TARGET,
    /// which is a request, not an observation. (Past the 3s fixture's end is the deterministic
    /// way to be outside every loaded range.)
    @Test("the pre-seek echo is projected — it carries the target, not the clock")
    func preSeekEchoIsProjected() async throws {
        let engine = try await readyEngine()
        let log = PositionBeatLog(engine)

        await engine.seek(to: CMTime(seconds: 100, preferredTimescale: 600))

        try await requireEventually({ log.beats.contains { $0.isBuffering } }, "no echo was published")
        let echo = try #require(log.beats.first { $0.isBuffering })
        #expect(echo.seconds == 100)
        #expect(echo.provenance == .projected)
        log.stop()
        await engine.teardown()
    }

    /// The other side: `AVPlayer` returned `finished == true` and no newer seek is outstanding,
    /// so the post-seek beat carries an observed clock. Weaker than VLC's convergence test —
    /// this asserts the seek RESOLVED, and the landing is only segment-accurate (default
    /// tolerance), which is exactly what the contract promises for this engine.
    @Test("the post-seek beat is observed and lands at the target")
    func postSeekBeatIsObserved() async throws {
        let engine = try await readyEngine()
        await engine.pause()
        let log = PositionBeatLog(engine)

        await engine.seek(to: CMTime(seconds: 2, preferredTimescale: 600))

        // Deliberately not "some observed beat exists" — a pre-seek observer tick at 0:00 is
        // observed too. The claim is that the beat AT THE TARGET is.
        try await requireEventually({ log.beats.contains { $0.provenance == .observed && $0.seconds > 1.5 } },
                                    "the seek never resolved at the target")
        let observed = try #require(log.beats.last { $0.provenance == .observed })
        #expect(abs(observed.seconds - 2) < 0.5, "landed at \(observed.seconds)s")
        // …and the beats INSIDE the window are labelled, which is the half the old assertion
        // only appeared to cover: it asked whether the first beat past 1.5s was non-observed,
        // which contradicts the wait above (that beat may BE the landing) and passed on a
        // measured accident — AVPlayer's periodic observer reports the target while the seek is
        // still outstanding, so the clock alone cannot tell the window from the landing. The
        // label can: everything published before the landing says `.stale`.
        //
        // Sliced at the landing rather than by position: an observed 0:00 tick can land between
        // the log's construction and the `seek(to:)` call, which is outside the window and
        // correctly observed.
        let landing = try #require(log.beats.firstIndex { $0.provenance == .observed && $0.seconds > 1.5 })
        #expect(log.beats[..<landing].filter { $0.seconds > 1.5 }.allSatisfy { $0.provenance == .stale },
                "a beat inside the seek window claimed an observed clock: \(log.beats)")
        log.stop()
        await engine.teardown()
    }

    /// Overlapping seeks: the NEWEST one owns every subsequent beat, and — the half this
    /// replaced got wrong — its own beat must not depend on the superseded call. Gating it on
    /// `inFlightSeeks == 0` made the winner's post-seek beat wait for the LOSER's continuation
    /// to have been resumed by AVFoundation first; a paused player (the drag-scrub flow pauses
    /// before seeking) then published no post-seek beat at all and the seek-fetch scrim never
    /// cleared. The serial says "I am the newest" without asking anyone else's state.
    ///
    /// Explicit `Task { @MainActor in … }`s rather than `async let`: an `async let` child is NOT
    /// actor-inherited, so the two seeks would hop onto this actor in whatever order the runtime
    /// picked and "the newest one" would be undefined — the test would have been asserting on a
    /// coin flip. Tasks enqueued on the main executor run in creation order, which makes
    /// "second supersedes first" a fact.
    ///
    /// The window itself cannot be held open against real AVFoundation — a seek on a ready,
    /// fully-buffered local fixture resolves before the test can look, and a pre-ready one
    /// resolves immediately with `finished == false` — and nothing here can pin which
    /// continuation resumes first either. So the claim is pinned on the outcome, which is what
    /// the contract actually promises: the newest target is observed, the superseded one is
    /// never observed, and the window is closed by the time the newest call returns.
    @Test("overlapping seeks: the newest target is observed, the superseded one publishes nothing")
    func supersededSeekObservesNothing() async throws {
        let engine = try await readyEngine()
        await engine.pause()
        let log = PositionBeatLog(engine)

        let first = Task { @MainActor in
            await engine.seek(to: CMTime(seconds: 2.5, preferredTimescale: 600))
        }
        let second = Task { @MainActor in
            await engine.seek(to: CMTime(seconds: 1, preferredTimescale: 600))
        }
        await second.value
        // Awaited BEFORE the superseded call: the newest seek closes the whole window itself,
        // rather than waiting for the older slot to drain.
        #expect(engine.inFlightSeeks == 0, "the newest seek left the window open")
        await first.value
        #expect(engine.inFlightSeeks == 0, "the superseded completion reopened the window")

        try await requireEventually({
            log.beats.contains { $0.provenance == .observed && abs($0.seconds - 1) < 0.5 }
        }, "the engine never observed the newest target")
        // And the superseded target owns nothing: its 2.5s landing is never evidence, in either
        // completion order. (Its pre-seek echo is `.buffering`/`.projected` — a request. An
        // observed 0:00 tick may precede both seeks; that one is the pre-seek clock, outside
        // either window.)
        #expect(log.beats.contains { $0.provenance == .observed && abs($0.seconds - 2.5) < 0.5 } == false,
                "the superseded seek published an observed beat: \(log.beats)")
        log.stop()
        await engine.teardown()
    }

    /// The load-time resume seek (`PlayableAsset.startTime`) is a seek like any other, and the
    /// seek-settle contract has to cover it: after a transcode re-anchor the app calls
    /// `load(startTime: B)`, so the NEW stream's first beats can be published while the resume
    /// is still queued against a not-yet-ready item. Labelled `.observed` they read as "the
    /// player really is at 00:00" — exactly the evidence a consumer uses to drop a held seek
    /// target, which would snap the bar to zero in the middle of the re-anchor.
    ///
    /// **What this can and cannot claim.** The window is armed synchronously — `load()` has no
    /// suspension point after it queues the seek — so `inFlightSeeks == 1` is an observation,
    /// not a race, and that is the half the defect was in. The other half, "the beats inside
    /// the window are `.stale`", turns out to be unreachable from a LOCAL 3-second fixture: the
    /// resume lands before the periodic observer's first tick, so the window opens and closes
    /// with nothing inside it. The original assertion was written as an `allSatisfy` over that
    /// empty set and passed without testing anything; measured, it is empty every run. So the
    /// claim is restated as what actually holds here — no beat escapes before the resume lands,
    /// least of all an observed 0:00 — and the labelling itself is covered on the VLC seam,
    /// where the window is long enough to stand inside.
    @Test("the load-time resume seek opens a settle window, and no beat escapes before it lands")
    func loadTimeResumeSeekOpensASettleWindow() async throws {
        let engine = AVKitEngine()
        let log = PositionBeatLog(engine)

        try await engine.load(.fixture(url: Self.fixture,
                                       startTime: CMTime(seconds: 1.5, preferredTimescale: 600)))
        #expect(engine.inFlightSeeks == 1, "the resume seek left the settle window closed")
        await engine.play()

        try await requireEventually({ log.beats.contains { $0.provenance == .observed } },
                                    "the resume never resolved")
        // `1.4` rather than `1.5` tolerates the segment-accurate landing AVPlayer's default
        // tolerance permits.
        #expect(log.beats.allSatisfy { $0.seconds >= 1.4 },
                "a beat escaped the resume window: \(log.beats.filter { $0.seconds < 1.4 })")
        log.stop()
        await engine.teardown()
    }

    /// A reload while an ordinary `seek(to:)` is outstanding. AVFoundation does not promise to
    /// resume a pending `player.seek` when the item is replaced, so without a per-item stamp
    /// that seek keeps its slot in `inFlightSeeks` forever: the counter never returns to zero
    /// and every beat of the NEW stream ships `.stale`, which on the app side is a seek hold
    /// only its watchdog can end. `detachCurrentItem` reclaims the slots; the generation is
    /// what stops the abandoned completion from then driving the count NEGATIVE, which would
    /// break `inFlightSeeks == 0` for the rest of the session in the other direction.
    ///
    /// The race itself cannot be held open against real AVFoundation — a seek on a ready local
    /// fixture resolves before the test can reload — so the abandoned completion is driven
    /// through `seekDidFinish(generation:)` directly. Everything around it is the real engine.
    @Test("a reload reclaims an abandoned seek's window, and its late completion is a no-op")
    func reloadReclaimsAnAbandonedSeeksWindow() async throws {
        let engine = AVKitEngine()
        let log = PositionBeatLog(engine)

        // The load-time resume seek is the only window a test can hold open deterministically:
        // it is queued against a not-yet-ready item and `load()` has no suspension point after
        // arming it. An ORDINARY `seek(to:)` cannot be held open — on a ready, fully-buffered
        // local fixture it resolves before the test can reload, and against a URL that never
        // becomes ready AVFoundation resolves it immediately instead of queueing it (measured,
        // both ways). Both paths close through `seekDidFinish(generation:)`, which is what the
        // rest of this test drives directly.
        try await engine.load(.fixture(url: Self.fixture,
                                       startTime: CMTime(seconds: 1.5, preferredTimescale: 600)))
        #expect(engine.inFlightSeeks == 1, "the seek never opened a settle window")
        let abandoned = engine.seekGeneration

        try await engine.load(.fixture(url: Self.fixture))   // the re-anchor discards that item
        #expect(engine.inFlightSeeks == 0, "the discarded item's window was never reclaimed")
        #expect(engine.seekGeneration != abandoned, "the new stream reused the discarded stamp")

        // The abandoned completion, delivered by hand: whether AVFoundation ever resumes that
        // `player.seek` is not something a test can pin, and the bookkeeping has to be right
        // either way. Reclaiming WITHOUT the stamp is the worse half of the bug — the count
        // would go to -1 and `inFlightSeeks == 0` would be false for the rest of the session.
        engine.seekDidFinish(generation: abandoned)
        #expect(engine.inFlightSeeks == 0, "an abandoned completion drove the count negative")

        await engine.play()
        try await requireEventually({ log.beats.contains { $0.provenance == .observed } },
                                    "the new stream never published an observed beat")
        log.stop()
        await engine.teardown()
    }

    /// `PlaybackEngine.seek(to:)` is documented as a no-op with no item loaded, and without the
    /// guard it was not one: it opened a settle window and awaited a seek AVFoundation does not
    /// promise to complete without a `currentItem` — an unresolved one strands the caller (a
    /// scrub commit) and leaves the slot open, which labels every later beat `.stale`.
    ///
    /// **This does not go red on iOS 26**: measured there, `AVPlayer.seek` resolves
    /// `finished == false` with no item, so the slot self-closes and both assertions hold
    /// either way. It stays as the regression pin for the contract — the no-op is ours to
    /// guarantee, not AVFoundation's to keep.
    @Test("a seek with no item loaded returns at once and counts nothing")
    func seekWithNoItemLoadedIsANoOp() async throws {
        let engine = AVKitEngine()

        await engine.seek(to: CMTime(seconds: 5, preferredTimescale: 600))

        #expect(engine.inFlightSeeks == 0, "the no-op seek leaked a settle window")
        #expect(engine.seekGeneration == 0, "the no-op seek superseded a batch that never existed")
        await engine.teardown()
    }
}
