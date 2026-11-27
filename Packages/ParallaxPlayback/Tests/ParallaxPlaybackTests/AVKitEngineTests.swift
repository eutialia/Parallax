import Foundation
import AVFoundation
import CoreMedia
import Testing
import ParallaxTestScaling
import ParallaxPlaybackTestSupport
import ParallaxCoreTestSupport
@testable import ParallaxPlayback

/// The real media every AVKit suite drives AVFoundation with. One home rather than a copy per
/// suite: what AVFoundation does with a real file is the whole point of these tests, so the
/// accessor is shared and the choice of file stays the test's own.
enum AVKitFixtures {
    /// 3 seconds, one embedded subtitle track — the seek-settle suite's material.
    static var subtitled: URL {
        get throws {
            try #require(
                Bundle.module.url(forResource: "subtitled", withExtension: "mp4", subdirectory: "Fixtures"),
                "subtitled.mp4 fixture missing from the test bundle"
            )
        }
    }

    /// The smallest playable file in the bundle — enough to reach `.readyToPlay` and nothing more.
    static var tiny: URL {
        get throws {
            try #require(
                Bundle.module.url(forResource: "tiny", withExtension: "mp4", subdirectory: "Fixtures"),
                "tiny.mp4 fixture missing from the test bundle"
            )
        }
    }

    /// An HLS presentation as a Jellyfin transcode serves it: 8 s of video and three WebVTT
    /// renditions, English, a forced-only French and German, in that order, each cue naming its
    /// rendition ("eng", "fra", "deu").
    static var subtitledStream: URL {
        get throws {
            try #require(
                Bundle.module.url(forResource: "subtitled-hls", withExtension: nil, subdirectory: "Fixtures"),
                "subtitled-hls fixture missing from the test bundle"
            )
        }
    }

    /// An HLS stream cut like a Jellyfin remux of a long-GOP source: the video is copied, so
    /// segments split only at keyframes, here 13 s apart (`-hls_time 6` asks for less). 40 s.
    static var longGOPStream: URL {
        get throws {
            try #require(
                Bundle.module.url(forResource: "long-gop-hls", withExtension: nil, subdirectory: "Fixtures"),
                "long-gop-hls fixture missing from the test bundle"
            )
        }
    }
}

extension AVKitEngine {
    /// The first beat on `state` that `match` accepts, or nil if none arrives within `timeout`.
    ///
    /// The load watchdog arms in `play()`, so a test that loads real media without playing it
    /// has nothing else to end an item that never turns ready, and the suite's time limit
    /// holds the CI step for ten minutes. A timeout cancels the drain, which finishes `state`
    /// for every consumer.
    func firstBeat(
        within timeout: Duration = CITimeScale.seconds(10),
        where match: @escaping @Sendable (PlaybackBeat) -> Bool
    ) async -> PlaybackBeat? {
        let drain = Task { [state] () -> PlaybackBeat? in
            for await beat in state where match(beat) { return beat }
            return nil
        }
        let deadline = Task {
            try await Ceiling.expire(timeout)
            drain.cancel()
        }
        defer { deadline.cancel() }
        return await drain.value
    }
}

extension PlaybackBeat {
    var isReadyOrFailed: Bool {
        switch state {
        case .ready, .failed: true
        default: false
        }
    }
}

/// The engine-agnostic half of the `PlaybackEngine` stream contract, run against AVKit.
// `.timeLimit`: `teardownFinishesStream` awaits a terminal nil from a real engine's stream.
// Swift Testing applies no default timeout, so an engine that never finishes its continuation
// wedges the whole run instead of failing its own test.
@Suite("PlaybackEngine stream contract", .serialized, .scaledTimeLimit())
@MainActor
struct PlaybackEngineStreamContractTests {

    @Test("the state stream is pre-seeded with .idle")
    func emitsIdleFirst() async {
        await PlaybackEngineContract.emitsIdleFirst(AVKitEngine(clock: TestClock()))
    }

    @Test("teardown finishes the state stream so consumers' for-await loops end")
    func teardownFinishesStream() async {
        await PlaybackEngineContract.teardownFinishesStream(AVKitEngine(clock: TestClock()))
    }

    @Test("a load goes through the same states, a seek lands the same way while playing, load throws the same errors, and subtitle options are numbered the same",
          arguments: PlaybackEngineClause.allCases)
    func matchesTheOtherEngine(clause: PlaybackEngineClause) async throws {
        try await PlaybackEngineContract.holds(clause) { AVKitStage() }
    }
}

/// `AVKitEngine` on real media. Its loads suspend only where the app's do: waiting for the
/// display to switch to the asset's mode.
@MainActor
final class AVKitStage: PlaybackEngineStage {
    private let avKit: AVKitEngine
    private let display = DisplaySwitch()
    private var server: HLSLoopbackServer?
    var engine: any PlaybackEngine { avKit }

    init() {
        let display = display
        avKit = AVKitEngine(clock: TestClock(), prepareDisplay: { _ in await display.switched() })
    }

    func subtitledStream() async throws -> PlayableAsset {
        let server = try HLSLoopbackServer.serving(
            directory: AVKitFixtures.subtitledStream, withholding: [], until: ResponseGate())
        self.server = server
        return .fixture(url: try await server.baseURL().appending(path: "master.m3u8"))
    }

    /// A closed loopback port refuses the connection at once, so this needs no server.
    func unplayableStream() -> PlayableAsset {
        .fixture(url: URL(string: "http://127.0.0.1:1/not-a-stream.m3u8")!)
    }

    /// Mounts a picture output, as the app mounts its layer: a headless player with neither a
    /// picture nor sound to play waits to minimize stalls for good.
    func mediaActs(on asset: PlayableAsset) async throws {
        avKit.avPlayer.currentItem?.add(AVPlayerItemVideoOutput(pixelBufferAttributes: nil))
    }
    func holdLoads() { display.hold() }
    func releaseLoads() { display.release() }
    var parkedLoads: Int { display.waiting }

    func tearDown() async {
        await avKit.teardown()
        server?.stop()
    }
}

/// A display mode switch that takes as long as the test holds it.
@MainActor
final class DisplaySwitch {
    private var isHeld = false
    private var parked: [CheckedContinuation<Void, Never>] = []
    var waiting: Int { parked.count }

    func hold() { isHeld = true }

    func release() {
        isHeld = false
        let due = parked
        parked = []
        due.forEach { $0.resume() }
    }

    func switched() async {
        guard isHeld else { return }
        await withCheckedContinuation { parked.append($0) }
    }
}

/// `redactedTail` is the only thing that ever writes an HLS resource URI into a log,
/// and the ApiKey rides in that URI's query — so dropping the query is a security
/// contract, not cosmetics. Exercised over generated Jellyfin-shaped URIs: resource names
/// mixed with the 32-hex and UUID item ids Jellyfin puts mid-path, under a query that carries
/// a secret.
@Suite("AVKitEngine — HLS error-log redaction")
@MainActor
struct AVKitLogRedactionTests {
    private static let names = ["Videos", "hls1", "main", "47.mp4", "-1.mp4", "master.m3u8", "main.m3u8", "init.mp4", "Audio"]

    private static func hex(_ count: Int, using random: inout SeededGenerator) -> String {
        String((0..<count).map { _ in "0123456789abcdef".randomElement(using: &random)! })
    }

    private static func component(using random: inout SeededGenerator) -> (text: String, isID: Bool) {
        switch Int.random(in: 0..<5, using: &random) {
        case 0: (hex(32, using: &random), true)
        case 1: ([8, 4, 4, 4, 12].map { hex($0, using: &random) }.joined(separator: "-"), true)
        default: (names.randomElement(using: &random)!, false)
        }
    }

    @Test("the tail is the last three resource names of the path, never the query or an item id")
    func tailNamesTheResource() {
        let seed = UInt64(0x7461_696C)
        var random = SeededGenerator(seed: seed)
        for _ in 0..<500 {
            let path = (0..<Int.random(in: 0...7, using: &random)).map { _ in Self.component(using: &random) }
            let secret = Self.hex(24, using: &random)
            let query = Bool.random(using: &random) ? "?ApiKey=\(secret)&PlaySessionId=\(Self.hex(8, using: &random))" : ""
            let trailing = Bool.random(using: &random) ? "/" : ""
            let uri = "https://jf.example.com/" + path.map(\.text).joined(separator: "/") + trailing + query
            let tail = AVKitEngine.redactedTail(of: uri)

            let resources = path.filter { !$0.isID }.map(\.text)
            let expected = resources.isEmpty ? nil : resources.suffix(3).joined(separator: "/")
            #expect(tail == expected, "seed \(seed): \(uri)")
            #expect(tail.map { !$0.contains(secret) && !$0.contains("?") } ?? true, "seed \(seed): \(uri)")
        }
    }
}

/// `PlayableAsset.engineSubtitlesDisabled` on the AVKit path.
/// AVFoundation has no switch to turn subtitles off, so the contract is enforced by deselecting the legible
/// group (once when the media selection groups load, once at `.ready` — AVPlayer applies
/// its own automatic selection between the two) and by refusing to select afterwards.
///
/// Driven against a real 3-second MP4 carrying two `mov_text` tracks: a fake could not
/// prove anything here, because the whole question is what AVFoundation does on its own.
// `.timeLimit`: every test here drains a real AVFoundation state stream until `.ready`. A
// simulator with a wedged mediaserverd (or a fixture that failed to copy) publishes neither
// beat; `firstBeat` bounds that wait, the limit bounds everything after it.
@Suite("AVKitEngine — assets that render their own subtitles", .serialized, .scaledTimeLimit())
@MainActor
struct AVKitSubtitleSuppressionTests {

    /// Loads the fixture and returns the inventory the engine publishes with `.ready`.
    private func loadAndAwaitReady(_ engine: AVKitEngine, disabled: Bool) async throws -> TrackInventory {
        try await engine.load(.fixture(url: AVKitFixtures.subtitled, engineSubtitlesDisabled: disabled))
        switch await engine.firstBeat(where: \.isReadyOrFailed)?.state {
        case .ready(_, let tracks)?: return tracks
        case .failed(let error)?: throw error
        default:
            Issue.record("the engine never reached .ready")
            return .empty
        }
    }

    @Test("reaches .ready with a legible group present and nothing selected in it")
    func readyPublishesNoLegibleSelection() async throws {
        let engine = AVKitEngine(clock: TestClock())
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
        let engine = AVKitEngine(clock: TestClock())
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
        let engine = AVKitEngine(clock: TestClock())
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
        let engine = AVKitEngine(clock: TestClock())
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
@Suite("AVKitEngine — the seek-settle contract", .serialized, .scaledTimeLimit())
@MainActor
struct AVKitSeekSettleTests {

    /// Loads the fixture and returns once the item is `.readyToPlay` (so `seek(to:)` reaches
    /// the real seek path rather than being queued against a not-yet-ready item).
    ///
    /// The drain in `firstBeat` is a SECOND consumer of `engine.state` — every caller then
    /// builds a `PositionBeatLog` over the same stream, and an `AsyncStream` has one buffer that
    /// its consumers race for. Safe only because this one is dead by then: it stops at `.ready`
    /// and its task has finished on return, so from the log's construction onward there is
    /// exactly one consumer. The ordering matters too — the log must be built AFTER this
    /// returns, which is what every caller does, or the two would split the beats.
    private func readyEngine(_ url: URL? = nil, clock: TestClock = TestClock()) async throws -> AVKitEngine {
        let engine = AVKitEngine(clock: clock)
        try await engine.load(.fixture(url: url ?? AVKitFixtures.subtitled))
        switch await engine.firstBeat(where: \.isReadyOrFailed)?.state {
        case .ready?: return engine
        case .failed(let error)?: throw error
        default:
            Issue.record("the engine never reached .ready")
            return engine
        }
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
    /// so the post-seek beat carries an observed clock. This asserts the seek RESOLVED; where it lands is `pausedSeekLandsInsideALongSegment`'s.
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
        #expect(abs(observed.seconds - 2) < 0.1, "landed at \(observed.seconds)s")
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

    /// A seek lands on its target, not on the first frame of the segment that holds it. A
    /// Jellyfin remux copies the source's video, so a segment runs from keyframe to keyframe,
    /// 13 s on a long-GOP source, and after an out-of-buffer seek the restarted job is still
    /// producing the target's segment. With AVPlayer's default tolerance the seek resolved at
    /// once on that segment's first frame: a scrub to 14:04 landed at 13:51. Paused,
    /// because that is how a scrub commits. The segment is withheld until the seek has asked
    /// for it, so the seek always starts with its segment still on the way. The fetch arms a
    /// stall deadline, and a seek that lands has to disarm it.
    @Test("a paused seek lands on its target while its long segment is still on the way")
    func pausedSeekLandsInsideALongSegment() async throws {
        let gate = ResponseGate()
        let server = try HLSLoopbackServer.serving(
            directory: AVKitFixtures.longGOPStream, withholding: ["/seg2.mp4"], until: gate
        )
        defer {
            gate.open()
            server.stop()
        }
        let clock = TestClock()
        let engine = try await readyEngine(try await server.baseURL().appending(path: "main.m3u8"), clock: clock)
        await engine.pause()
        let log = PositionBeatLog(engine)

        let seek = Task { await engine.seek(to: CMTime(seconds: 33, preferredTimescale: 600)) }   // segment 2 is 26–39 s
        // The paused player can ask for the segment on its own before the seek task runs, so
        // the request alone doesn't say the seek has started; its armed deadline does.
        try await clock.waitForSleep(dueIn: .seconds(45))
        try await requireEventually({ server.pathsRequested.contains("/seg2.mp4") },
                                    "the seek never asked for its segment")
        gate.open()
        await seek.value

        try await requireEventually({ log.beats.contains { $0.provenance == .observed && $0.seconds >= 26 } },
                                    "the seek never resolved")
        let landing = try #require(log.beats.last { $0.provenance == .observed })
        #expect(abs(landing.seconds - 33) < 0.1, "landed at \(landing.seconds)s")
        #expect(clock.pendingSleeps.isEmpty, "a seek that landed left its stall deadline running")
        log.stop()
        await engine.teardown()
    }

    /// A paused seek fetches without entering `.waitingToPlayAtSpecifiedRate`, the only state
    /// that arms the stall watchdog, and `player.seek` waits for the target's segment at any
    /// tolerance: on a dead link it stays pending (measured past 30 s). So a scrub into a segment
    /// that never comes waited on the buffering scrim for good. It has to end the way any other
    /// stall does.
    @Test("a paused seek whose segment never arrives fails as a stall")
    func pausedSeekIntoADeadSegmentFailsAsAStall() async throws {
        let gate = ResponseGate()
        let server = try HLSLoopbackServer.serving(
            directory: AVKitFixtures.longGOPStream, withholding: ["/seg2.mp4"], until: gate
        )
        defer {
            gate.open()
            server.stop()
        }
        let clock = TestClock()
        let engine = try await readyEngine(try await server.baseURL().appending(path: "main.m3u8"), clock: clock)
        await engine.pause()

        final class Flag { var isSet = false }
        let seekReturned = Flag()
        Task {
            await engine.seek(to: CMTime(seconds: 33, preferredTimescale: 600))   // segment 2 is 26–39 s
            seekReturned.isSet = true
        }
        try await clock.waitForSleep(dueIn: .seconds(45))
        clock.advance(by: .seconds(45))

        let failure = await engine.firstBeat(within: CITimeScale.seconds(5)) {
            if case .failed = $0.state { true } else { false }
        }
        guard case .failed(let error)? = failure?.state else {
            Issue.record("the seek waited on its dead segment without failing")
            return
        }
        #expect(error == .networkStalled)
        // The scrub commit that issued the seek is still suspended in it. Teardown has to hand
        // it back, or the commit outlives the session it was made in.
        // Polled, not joined: a seek teardown left pending never returns, and the gate opens
        // only once this test does.
        await engine.teardown()
        try await requireEventually({ seekReturned.isSet }, "teardown left the dead seek pending")
    }

    /// The item can end while a seek still waits on its segment. A stall deadline left running
    /// past that would fail the session a second time and replace what it really reported.
    @Test("a terminal state ends a waiting seek's stall deadline")
    func terminalStateDisarmsAWaitingSeeksDeadline() async throws {
        let gate = ResponseGate()
        let server = try HLSLoopbackServer.serving(
            directory: AVKitFixtures.longGOPStream, withholding: ["/seg2.mp4"], until: gate
        )
        defer {
            gate.open()
            server.stop()
        }
        let clock = TestClock()
        let engine = AVKitEngine(clock: clock)
        let session = try await engine.load(.fixture(url: try await server.baseURL().appending(path: "main.m3u8")))
        #expect(await engine.firstBeat(where: \.isReadyOrFailed).map { if case .ready = $0.state { true } else { false } } == true)
        await engine.pause()

        let seek = Task { await engine.seek(to: CMTime(seconds: 33, preferredTimescale: 600)) }
        try await clock.waitForSleep(dueIn: .seconds(45))

        engine.handleEnded(from: session)
        #expect(clock.pendingSleeps.isEmpty, "the item ended and its seek's stall deadline kept running")
        // The dead-segment test owns teardown with the segment withheld; here the seek just ends.
        gate.open()
        await engine.teardown()
        await seek.value
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
        let engine = AVKitEngine(clock: TestClock())
        let log = PositionBeatLog(engine)

        // The load-time resume seek is the only window a test can hold open deterministically:
        // it is queued against a not-yet-ready item and `load()` has no suspension point after
        // arming it. An ORDINARY `seek(to:)` cannot be held open — on a ready, fully-buffered
        // local fixture it resolves before the test can reload, and against a URL that never
        // becomes ready AVFoundation resolves it immediately instead of queueing it (measured,
        // both ways). Both paths close through `seekDidFinish(generation:)`, which is what the
        // rest of this test drives directly.
        try await engine.load(.fixture(url: AVKitFixtures.subtitled,
                                       startTime: CMTime(seconds: 1.5, preferredTimescale: 600)))
        #expect(engine.inFlightSeeks == 1, "the seek never opened a settle window")
        let abandoned = engine.seekGeneration

        try await engine.load(.fixture(url: AVKitFixtures.subtitled))   // the re-anchor discards that item
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

    /// The resume of a transcode re-anchor waits on a segment the server has not cut yet, and a
    /// second reload can land before it does. AVFoundation does not promise to resolve a seek
    /// queued against an item it no longer plays, and the new stream's clock is not that seek's.
    @Test("a reload that abandons a queued resume seek publishes the new stream's clock as observed")
    func reloadOverAQueuedResumeSeekObservesTheNewStream() async throws {
        let gate = ResponseGate()
        let server = try HLSLoopbackServer.serving(
            directory: AVKitFixtures.longGOPStream, withholding: ["/seg2.mp4"], until: gate)
        defer {
            gate.open()
            server.stop()
        }
        let engine = AVKitEngine(clock: TestClock())
        let log = PositionBeatLog(engine)
        try await engine.load(.fixture(url: try await server.baseURL().appending(path: "main.m3u8"),
                                       startTime: CMTime(seconds: 30, preferredTimescale: 600)))
        await engine.play()
        try await requireEventually({ server.pathsRequested.contains("/seg2.mp4") },
                                    "the resume never asked for its segment")

        let reloaded = try await engine.load(.fixture(url: AVKitFixtures.subtitled))
        await engine.play()
        try await requireEventually({ log.beats.contains { $0.provenance == .observed && !$0.isBuffering && $0.seconds > 0.5 } },
                                    "the new stream never published an observed beat", timeout: CITimeScale.seconds(10))
        #expect(reloaded != .none)
        log.stop()
        await engine.teardown()
    }

    @Test("a seek before anything is loaded returns, and the stream loaded after it publishes its clock as observed")
    func seekBeforeALoadLeavesTheStreamObserved() async throws {
        let engine = AVKitEngine(clock: TestClock())
        let log = PositionBeatLog(engine)
        await engine.seek(to: CMTime(seconds: 5, preferredTimescale: 600))

        try await engine.load(.fixture(url: AVKitFixtures.subtitled))
        await engine.play()
        try await requireEventually({ log.beats.contains { $0.provenance == .observed && !$0.isBuffering && $0.seconds > 0.5 } },
                                    "the stream never published an observed beat", timeout: CITimeScale.seconds(10))
        #expect(log.beats.allSatisfy { $0.seconds < 4.5 }, "the seek before the load moved the stream: \(log.beats)")
        log.stop()
        await engine.teardown()
    }

    /// The same overlap, seen from the stream: the newest target is observed, the superseded
    /// one never is, and once both have returned the clock is observed again.
    @Test("overlapping seeks: the newest target is observed, the superseded one never is, and playback after them is observed")
    func overlappingSeeksSettleOnTheNewest() async throws {
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
        try await requireEventually({
            log.beats.contains { $0.provenance == .observed && abs($0.seconds - 1) < 0.5 }
        }, "the engine never observed the newest target")
        await first.value
        let settled = log.beats
        #expect(settled.contains { $0.provenance == .observed && abs($0.seconds - 2.5) < 0.5 } == false,
                "the superseded seek published an observed beat: \(settled)")
        await engine.play()
        try await requireEventually({
            log.beats.dropFirst(settled.count).contains { $0.provenance == .observed && !$0.isBuffering && $0.seconds > 1.2 }
        }, "playback after the seeks was never observed")
        log.stop()
        await engine.teardown()
    }

    @Test("no beat of a resumed HLS stream escapes before its resume lands")
    func resumeOnAStreamPublishesNothingBeforeItLands() async throws {
        let server = try HLSLoopbackServer.serving(
            directory: AVKitFixtures.longGOPStream, withholding: [], until: ResponseGate())
        defer { server.stop() }
        let engine = AVKitEngine(clock: TestClock())
        let log = PositionBeatLog(engine)
        try await engine.load(.fixture(url: try await server.baseURL().appending(path: "main.m3u8"),
                                       startTime: CMTime(seconds: 30, preferredTimescale: 600)))
        await engine.play()

        try await requireEventually({ log.beats.contains { $0.provenance == .observed && !$0.isBuffering } },
                                    "the resume never resolved", timeout: CITimeScale.seconds(10))
        // The resume lands on its segment's first frame, at 26 s.
        let early = log.beats.filter { $0.provenance == .observed && $0.seconds < 25.9 }
        #expect(early.isEmpty, "an observed beat escaped the resume window: \(early)")
        log.stop()
        await engine.teardown()
    }
}

/// Which of the engine's item-scoped callbacks is being driven from a session the reload has
/// already replaced. Every one of them is live for seconds after a re-anchor arms: KVO and
/// notification blocks sit on the main run loop, the inventory load is only cancelled inside the
/// NEXT `load()`, and both watchdogs are timers with their own deadline.
enum SupersededCallback: String, CaseIterable, CustomTestStringConvertible {
    case statusKVO
    case endNotification
    case periodicTick
    case trackInventory
    case loadWatchdog
    case stallWatchdog

    var testDescription: String { rawValue }
}

/// A reload keeps the AVPlayer (so the surface holds its last frame) and swaps only the item,
/// which leaves every callback the OUTGOING media installed in flight. On a transcode re-anchor
/// the outgoing HLS playlist has been yanked out from under that item by then — the encode job is
/// killed before the replacement resolves — so what those callbacks run with is a failure, and a
/// `.failed` adopted as the live session's is the "Couldn't decode this file" scrim over a reload
/// that is buffering perfectly well.
///
/// The race cannot be held open against real AVFoundation, so the superseded session is captured
/// and its callbacks delivered by hand. Everything around them is the real engine.
// `.timeLimit`: each case drains a real AVFoundation stream until the new item is `.ready`.
@Suite("AVKitEngine — a superseded session publishes nothing", .serialized, .scaledTimeLimit(minutes: 2))
@MainActor
struct AVKitSupersededSessionTests {

    @Test("no callback of a superseded session reaches the stream",
          arguments: SupersededCallback.allCases)
    func supersededSessionPublishesNothing(callback: SupersededCallback) async throws {
        let engine = AVKitEngine(clock: TestClock())

        // Session A, driven to the state this callback needs. `.statusKVO` wants an item that
        // really failed — nothing here stubs `status`, AVFoundation owns it.
        let staleURL = callback == .statusKVO
            ? URL(fileURLWithPath: "/dev/null/not-a-movie.mp4")
            : try AVKitFixtures.tiny
        let stale = try await engine.load(.fixture(url: staleURL))
        try #require(await engine.firstBeat(where: \.isReadyOrFailed) != nil, "session A never settled")
        let staleItem = try #require(engine.currentItem)
        // The inventory load is spawned while the session is still live and only cancelled
        // inside the NEXT `load()` — seconds into a re-anchor. That is the race, so it starts
        // here rather than being driven after the boundary.
        if callback == .trackInventory {
            engine.handleStatusChange(staleItem, from: stale)
        }

        // Session B: the reload. Everything above is superseded from this line on.
        let live = try await engine.load(.fixture(url: AVKitFixtures.tiny))
        #expect(live != stale, "the reload never opened a new session")

        switch callback {
        case .statusKVO:
            engine.handleStatusChange(staleItem, from: stale)
        case .endNotification:
            engine.handleEnded(from: stale)
        case .periodicTick:
            engine.emitTimeUpdate(at: CMTime(seconds: 1, preferredTimescale: 600),
                                  of: staleItem, from: stale)
        case .trackInventory:
            // Already in flight, parked on these two loads. Joining them here puts its beat,
            // if the stamp let one through, ahead of the live `.ready` drained below.
            let staleAsset = try #require(staleItem.asset as? AVURLAsset)
            _ = try? await staleAsset.loadMediaSelectionGroup(for: .audible)
            _ = try? await staleAsset.loadMediaSelectionGroup(for: .legible)
        case .loadWatchdog:
            engine.handleLoadTimeout(from: stale)
        case .stallWatchdog:
            engine.handleStallTimeout(from: stale)
        }

        // The live session's own `.ready` is the sync point: `yield` is synchronous, so anything
        // a callback published is already ahead of it in the buffer.
        let liveReady = await engine.firstBeat { beat in
            #expect(beat.session != stale,
                    "a superseded \(callback.rawValue) beat reached the stream: \(beat.state)")
            if case .ready = beat.state, beat.session == live { return true }
            return false
        }
        #expect(liveReady != nil, "the reload never reached .ready")
        await engine.teardown()
        var iterator = engine.state.makeAsyncIterator()
        while let beat = await iterator.next() {
            #expect(beat.session != stale,
                    "a superseded \(callback.rawValue) beat reached the stream late: \(beat.state)")
        }
    }
}

/// An Apple TV that switches frame rate while AVPlayer chooses a variant fails the item with
/// `AVErrorNoCompatibleAlternatesForExternalDisplay`, so the display is asked before the item
/// reaches the player.
@Suite("AVKitEngine — the display is prepared before the item reaches the player", .serialized, .scaledTimeLimit())
@MainActor
struct AVKitDisplayPreparationTests {
    @MainActor
    final class Preparations {
        var engine: AVKitEngine?
        var playerHadItem: [Bool] = []
        var preparedURLs: [URL] = []
        var tearsDown = false
    }

    private static func engine(_ preparations: Preparations) -> AVKitEngine {
        let engine = AVKitEngine(clock: TestClock(), prepareDisplay: { [preparations] asset in
            preparations.playerHadItem.append(preparations.engine?.avPlayer.currentItem != nil)
            if let url = (asset as? AVURLAsset)?.url { preparations.preparedURLs.append(url) }
            if preparations.tearsDown { await preparations.engine?.teardown() }
        })
        preparations.engine = engine
        return engine
    }

    @Test("the display is prepared with the player still empty, and the item follows")
    func preparesBeforeTheItemAttaches() async throws {
        let preparations = Preparations()
        let engine = Self.engine(preparations)

        let fixture = try AVKitFixtures.tiny
        try await engine.load(.fixture(url: fixture))

        #expect(preparations.playerHadItem == [false])
        #expect(preparations.preparedURLs == [fixture])
        #expect((engine.avPlayer.currentItem?.asset as? AVURLAsset)?.url == fixture)
        await engine.teardown()
    }

    @Test("a reload on the same engine, a track switch, does not prepare again")
    func reloadDoesNotPrepareAgain() async throws {
        let preparations = Preparations()
        let engine = Self.engine(preparations)

        try await engine.load(.fixture(url: AVKitFixtures.tiny))
        try await engine.load(.fixture(url: AVKitFixtures.tiny))

        #expect(preparations.playerHadItem.count == 1)
        await engine.teardown()
    }

    @Test("a teardown while the display switches leaves the player empty")
    func teardownDuringPreparationAttachesNothing() async throws {
        let preparations = Preparations()
        preparations.tearsDown = true
        let engine = Self.engine(preparations)

        await #expect(throws: CancellationError.self) {
            try await engine.load(.fixture(url: AVKitFixtures.tiny))
        }
        #expect(engine.avPlayer.currentItem == nil)
    }
}
