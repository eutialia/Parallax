import Foundation
import AVFoundation
import CoreMedia
import Testing
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
