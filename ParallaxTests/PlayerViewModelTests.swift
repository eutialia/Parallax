import Foundation
import CoreMedia
import MediaPlayer
import Testing
@testable import Parallax
import ParallaxPlayback
import ParallaxPlaybackTestSupport
import ParallaxSubtitles
import ParallaxTestScaling
@testable import ParallaxJellyfin
@testable import ParallaxCore

/// One engine-routing case: what the server resolved, and the delivered hints + engine
/// the selector must derive from it. A plain enum rather than prebuilt fixtures so the
/// `arguments:` table stays evaluable outside the suite's MainActor isolation.
private enum RoutingCase: String, CaseIterable, CustomTestStringConvertible {
    /// Source is MKV/AV1/DTS but the server DELIVERS an HLS transcode: the selector
    /// must gate on the delivery (AVKit-playable), not the source container.
    case transcodedMKVDeliversHLS
    /// VC-1 sits outside EngineSelector's avKit video-codec set → .vlcKit.
    case vc1MKVDirectPlay
    /// Same source with an AVKit-playable AAC track — the video codec still decides.
    case vc1MKVWithAACAudio
    /// Container AND codec both outside the avKit whitelist → .vlcKit.
    case vp9WebMDirectPlay

    var testDescription: String { rawValue }

    /// The delivered hints (`PlayerViewModel.deliveredHints`) and the engine id the
    /// factory must be asked for. A transcode's hints carry NO codecs — the HLS
    /// rendition targets the device profile, so the source codecs are irrelevant.
    var expected: (container: Container, videoCodec: VideoCodec?, engine: PlaybackEngineID) {
        switch self {
        case .transcodedMKVDeliversHLS: (.hls, nil, .avKit)
        case .vc1MKVDirectPlay: (.mkv, .vc1, .vlcKit)
        case .vc1MKVWithAACAudio: (.mkv, .vc1, .vlcKit)
        case .vp9WebMDirectPlay: (.webm, .vp9, .vlcKit)
        }
    }
}

/// The two live-job shapes the seek gate must treat IDENTICALLY: a stream-copied video
/// (remux) and a re-encoded one. One argument table so a delivery-based exemption can
/// never sneak back in for only one of them.
private let deliveryShapes = [
    // Video stream-COPIED (remux) — audio is the only re-encode.
    TranscodeDelivery(isVideoDirect: true, isAudioDirect: false,
                      videoCodec: "hevc", audioCodec: "aac",
                      transcodeReasons: ["AudioCodecNotSupported"]),
    // Video RE-ENCODED — the #15845 accurate-seek drift failure mode.
    TranscodeDelivery(isVideoDirect: false, isAudioDirect: true,
                      videoCodec: "h264", audioCodec: "ac3",
                      transcodeReasons: ["VideoCodecNotSupported"]),
]

// .serialized is required because several tests write to MPNowPlayingInfoCenter.default(),
// which is a process-wide singleton. Parallel async tests interleave at `await` points
// and clobber each other's nowPlayingInfo state even when the NowPlaying sub-suite itself
// is serialized, because outer-suite tests (e.g. teardownReportsStopped calling vm.stop()
// → nowPlaying.clear()) run concurrently with the inner suite.
@Suite("PlayerViewModel integration", .serialized)
@MainActor
struct PlayerViewModelTests {
    @Test("resolves, selects .avKit, loads + plays, maps states, emits beats in order")
    func happyPath() async throws {
        let reporting = StubPlaybackReporting()
        let engine = FakePlaybackEngine(id: .avKit, capabilities: .avKit)
        let resolved = PlayerFixtures.resolved()
        var resolvedItemID: ItemID?

        let vm = makePlayerVM(
            reporting: reporting,
            engine: engine,
            resolved: resolved,
            capturedItem: { resolvedItemID = $0 }
        )

        await vm.start(item: PlayerFixtures.movieDetail())

        // Resolve happened with the right item; engine was selected + driven.
        #expect(resolvedItemID == ItemID(rawValue: "movie-1"))
        #expect(!engine.loadedAssets.isEmpty)
        #expect(engine.loadedAssets.first?.hints.container == .mp4)
        #expect(engine.calls.contains("play"))

        // Script ready → play → progress → ended through the single consumer.
        engine.push(.ready(duration: resolved.runtime!, tracks: .empty))
        engine.push(.playing(10, duration: resolved.runtime!))
        engine.push(.playing(20, duration: resolved.runtime!))
        engine.push(.ended)
        engine.finish()

        // Drain: the consumer runs real awaits between beats (preferred-track
        // apply on .ready, session teardown on .ended), so a fixed sleep races
        // it. Poll for the full beat sequence with a bounded deadline instead.
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while await reporting.events.count < 3, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }

        #expect(vm.phase == .playing)

        let events = await reporting.events
        #expect(events == [
            .start(ticks: 10 * 10_000_000, isPaused: false, itemID: "movie-1"),
            .progress(ticks: 20 * 10_000_000, isPaused: false, itemID: "movie-1"),
            .stopped(ticks: 20 * 10_000_000, itemID: "movie-1"),
        ])
    }

    @Test("startupMillis is set after the first .playing beat, and stays put across a later .playing beat")
    func startupMillisSetOnFirstPlayingBeat() async throws {
        let reporting = StubPlaybackReporting()
        let engine = FakePlaybackEngine(id: .avKit, capabilities: .avKit)
        let resolved = PlayerFixtures.resolved()
        let vm = makePlayerVM(reporting: reporting, engine: engine, resolved: resolved)

        #expect(vm.startupMillis == nil)

        await vm.start(item: PlayerFixtures.movieDetail())
        #expect(vm.startupMillis == nil)   // not yet — no .playing beat landed

        engine.push(.playing(10, duration: resolved.runtime!))
        try await engine.settle()

        let first = try #require(vm.startupMillis)
        #expect(first >= 0)

        // A later .playing beat (e.g. resume-from-pause) must NOT overwrite the metric —
        // it belongs to the session's FIRST beat only.
        engine.push(.paused(15, duration: resolved.runtime!))
        engine.push(.playing(16, duration: resolved.runtime!))
        try await engine.settle()

        #expect(vm.startupMillis == first)
    }

    @Test("startupMillis resets across a transcode track-switch reload and is recaptured by the new session's first .playing beat")
    func startupMillisResetsOnReload() async throws {
        let reporting = StubPlaybackReporting()
        let resolved = PlayerFixtures.resolvedMultiTrackTranscode()

        nonisolated(unsafe) var createdEngines: [FakePlaybackEngine] = []
        let vm = makePlayerVM(
            reporting: reporting,
            resolve: { _, _, _, _ in resolved },
            engineFactory: { _, _ in
                let engine = FakePlaybackEngine(id: .avKit, capabilities: .avKit)
                createdEngines.append(engine)
                return engine
            }
        )
        await vm.start(item: PlayerFixtures.movieDetail())
        let engine = try #require(vm.engine as? FakePlaybackEngine)

        engine.push(.playing(100))
        try await engine.settle()
        #expect(vm.startupMillis != nil)

        // Switch audio → the engine is RELOADED in place (same instance, same stream —
        // see transcodeSwitchReusesEngine). The reload's lifecycle reset must clear the
        // old session's metric before its own engine.play() re-arms the anchor.
        let audio4 = try #require(vm.availableAudioTracks.first { $0.id == .jellyfinStream(4) })
        await vm.selectAudioTrack(audio4)
        #expect(vm.startupMillis == nil)

        engine.push(.playing(0))
        try await engine.settle()
        #expect(vm.startupMillis != nil)
    }

    @Test("incomplete media: a live beat with an unknown duration is controllable but not seekable")
    func unknownDurationIsControllableNotSeekable() async throws {
        let reporting = StubPlaybackReporting()
        let engine = FakePlaybackEngine(id: .vlcKit, capabilities: .vlcKit)
        let resolved = PlayerFixtures.resolved()
        let vm = makePlayerVM(reporting: reporting, engine: engine, resolved: resolved)

        await vm.start(item: PlayerFixtures.movieDetail())

        // libvlc never resolves the length of a truncated/incomplete file, so the engine ships
        // a live beat with an `.indefinite` duration (instead of suppressing it and wedging the
        // player in `.loading`). The player must become controllable (`phase == .playing`) yet
        // report itself non-seekable — there's no scrubbable timeline without a known length.
        engine.push(.playing(5, duration: .indefinite))
        engine.finish()
        try await engine.settle()

        #expect(vm.phase == .playing)
        #expect(vm.hasKnownDuration == false)
    }

    @Test("complete media: a live beat with a real duration reports a known, seekable duration")
    func knownDurationIsSeekable() async throws {
        let reporting = StubPlaybackReporting()
        let engine = FakePlaybackEngine(id: .vlcKit, capabilities: .vlcKit)
        let resolved = PlayerFixtures.resolved()
        let vm = makePlayerVM(reporting: reporting, engine: engine, resolved: resolved)

        await vm.start(item: PlayerFixtures.movieDetail())
        engine.push(.playing(5, duration: resolved.runtime!))
        engine.finish()
        try await engine.settle()

        #expect(vm.phase == .playing)
        #expect(vm.hasKnownDuration == true)
    }

    @Test("audio session activation failure surfaces a distinct error and short-circuits before resolve")
    func audioSessionFailureIsDistinctAndShortCircuits() async {
        let reporting = StubPlaybackReporting()
        let engine = FakePlaybackEngine(id: .avKit, capabilities: .avKit)
        var didResolve = false

        let vm = makePlayerVM(
            reporting: reporting,
            engine: engine,
            resolved: PlayerFixtures.resolved(),
            audioSession: ThrowingAudioSession(),
            capturedItem: { _ in didResolve = true }
        )

        await vm.start(item: PlayerFixtures.movieDetail())

        // A failed audio session is NOT a network problem — it must not be
        // reported as ".resourceUnavailable" ("Couldn't reach the file…").
        #expect(vm.phase == .failed(.playback(.audioSessionFailed)))
        #expect(vm.phase != .failed(.playback(.resourceUnavailable)))
        // activate() throws before resolve() runs, so nothing downstream fired.
        #expect(didResolve == false)
        #expect(engine.loadedAssets.isEmpty)
    }

    @Test("engine routing follows the DELIVERED hints and asks the factory for the matching engine",
          arguments: RoutingCase.allCases)
    fileprivate func engineRoutingFollowsDeliveredHints(routing: RoutingCase) async {
        let resolved: ResolvedPlayback = switch routing {
        case .transcodedMKVDeliversHLS: PlayerFixtures.resolvedTranscodedMKV()
        case .vc1MKVDirectPlay: PlayerFixtures.resolvedVC1MKV()
        case .vc1MKVWithAACAudio: PlayerFixtures.resolvedVC1MKV(audioCodec: .aac)
        case .vp9WebMDirectPlay: PlayerFixtures.resolvedVP9WebM()
        }
        let expected = routing.expected
        // The factory hands back the fake regardless of the id it's asked for, so the
        // captured id — not the fake's own — is the routing evidence.
        let engine = FakePlaybackEngine(id: expected.engine, capabilities: .avKit)
        nonisolated(unsafe) var requestedEngineID: PlaybackEngineID?
        let vm = makePlayerVM(
            resolve: { _, _, _, _ in resolved },
            engineFactory: { id, _ in requestedEngineID = id; return engine }
        )

        await vm.start(item: PlayerFixtures.movieDetail())

        #expect(requestedEngineID == expected.engine)
        #expect(vm.phase != .failed(.playback(.unsupportedFormat)))
        let asset = engine.loadedAssets.first
        #expect(asset != nil)
        #expect(asset?.hints.container == expected.container)
        #expect(asset?.hints.videoCodec == expected.videoCodec)
        #expect(engine.calls.contains("play"))
    }

    @Test("teardown reports stopped and finishes the engine")
    func teardownReportsStopped() async throws {
        let reporting = StubPlaybackReporting()
        let engine = FakePlaybackEngine(id: .avKit, capabilities: .avKit)
        let resolved = PlayerFixtures.resolved()

        let vm = makePlayerVM(reporting: reporting, engine: engine, resolved: resolved)
        await vm.start(item: PlayerFixtures.movieDetail())
        engine.push(.playing(30, duration: resolved.runtime!))
        try await engine.settle()

        await vm.stop()
        #expect(engine.calls.contains("teardown"))

        let events = await reporting.events
        #expect(events.contains(.stopped(ticks: 30 * 10_000_000, itemID: "movie-1")))
    }

    @Test("chapterFractions is empty until a duration beat, then maps chapters to 0...1")
    func chapterFractionsTrackDuration() async throws {
        let reporting = StubPlaybackReporting()
        let engine = FakePlaybackEngine(id: .avKit, capabilities: .avKit)

        let vm = makePlayerVM(reporting: reporting, engine: engine, resolved: PlayerFixtures.resolved())
        // Chapters at 0 / 600 / 1200s; the duration arrives only with the engine beat.
        await vm.start(item: PlayerFixtures.movieDetailWithChapters(startsSeconds: [0, 600, 1200],
                                                                    runtime: .seconds(1200)))

        // Chapters are known but the duration isn't yet — no fractions to map onto.
        #expect(vm.chapterFractions.isEmpty)

        engine.push(.playing(10, duration: .seconds(1200)))
        try await engine.settle()

        #expect(vm.chapterFractions == [0, 0.5, 1.0])

        // A repeat duration beat must NOT disturb the cached value (the memoization gate).
        engine.push(.playing(20, duration: .seconds(1200)))
        try await engine.settle()
        #expect(vm.chapterFractions == [0, 0.5, 1.0])
    }

    @Test("chapterFractions clears on stop")
    func chapterFractionsClearOnStop() async throws {
        let reporting = StubPlaybackReporting()
        let engine = FakePlaybackEngine(id: .avKit, capabilities: .avKit)

        let vm = makePlayerVM(reporting: reporting, engine: engine, resolved: PlayerFixtures.resolved())
        await vm.start(item: PlayerFixtures.movieDetailWithChapters(startsSeconds: [0, 300], runtime: .seconds(600)))
        engine.push(.playing(5, duration: .seconds(600)))
        try await engine.settle()
        #expect(vm.chapterFractions == [0, 0.5])

        await vm.stop()
        #expect(vm.chapterFractions.isEmpty)
    }

    @Test("availableAudio/SubtitleTracks start empty and populate on .ready")
    func trackStatePopulatesOnReady() async throws {
        let reporting = StubPlaybackReporting()
        let engine = FakePlaybackEngine(id: .avKit, capabilities: .avKit)
        let vm = makePlayerVM(reporting: reporting, engine: engine, resolved: PlayerFixtures.resolved())
        await vm.start(item: PlayerFixtures.movieDetail())

        #expect(vm.availableAudioTracks.isEmpty)
        #expect(vm.availableSubtitleTracks.isEmpty)
        #expect(vm.selectedAudioTrack == nil)
        #expect(vm.selectedSubtitleTrack == nil)

        let inventory = TrackInventory(
            audio: [
                AudioTrack(id: .avKitOption(1), displayName: "English", languageCode: "en"),
                AudioTrack(id: .avKitOption(2), displayName: "French", languageCode: "fr"),
            ],
            subtitles: [
                SubtitleTrack(id: .avKitOption(1), displayName: "English SDH", languageCode: "en", isForced: false),
            ]
        )
        engine.push(.ready(duration: CMTime(seconds: 7200, preferredTimescale: 600), tracks: inventory))
        try await engine.settle()

        #expect(vm.availableAudioTracks.count == 2)
        #expect(vm.availableSubtitleTracks.count == 1)
        #expect(vm.selectedAudioTrack == nil)
        #expect(vm.selectedSubtitleTrack == nil)
    }

    @Test(".ready seeds the engine's default-selected audio/subtitle so the menu shows a checkmark")
    func readySeedsDefaultSelection() async throws {
        let reporting = StubPlaybackReporting()
        let engine = FakePlaybackEngine(id: .avKit, capabilities: .avKit)
        let vm = makePlayerVM(reporting: reporting, engine: engine, resolved: PlayerFixtures.resolved())
        await vm.start(item: PlayerFixtures.movieDetail())

        let inventory = TrackInventory(
            audio: [
                AudioTrack(id: .avKitOption(0), displayName: "Audio 1", languageCode: nil),
                AudioTrack(id: .avKitOption(1), displayName: "English", languageCode: "en"),
            ],
            subtitles: [
                SubtitleTrack(id: .avKitOption(0), displayName: "English", languageCode: "en", isForced: false),
            ],
            selectedAudioID: .avKitOption(1),
            selectedSubtitleID: nil
        )
        engine.push(.ready(duration: CMTime(seconds: 3600, preferredTimescale: 600), tracks: inventory))
        try await engine.settle()

        #expect(vm.selectedAudioTrack?.id == .avKitOption(1))     // reflects engine default, not just first
        #expect(vm.selectedSubtitleTrack == nil)      // nil subtitle id == "Off"
    }

    @Test("direct-play: a server-preferred EXTERNAL sub deselects the engine subtitle so an embedded default can't show through the client overlay")
    func directPlayExternalSubtitleDeselectsEngine() async throws {
        let reporting = StubPlaybackReporting()
        let engine = FakePlaybackEngine(id: .vlcKit, capabilities: .vlcKit)
        let resolved = PlayerFixtures.resolvedDirectPlayExternalSub()
        let vm = makePlayerVM(reporting: reporting, engine: engine, resolved: resolved)
        await vm.start(item: PlayerFixtures.movieDetail())

        // Engine inventory with NO subtitle pre-selected: the external default is the
        // server's choice, rendered client-side — not one of the engine's own tracks.
        engine.push(.ready(duration: resolved.runtime!, tracks: .empty))
        try await engine.settle()

        // The external sidecar is the active selection…
        #expect(vm.selectedSubtitleTrack?.id == .jellyfinStream(2))
        // …and the engine was told to drop its own subtitle. Before the fix the
        // server-preferred path skipped this deselect, so VLC's auto-picked embedded
        // sub rendered THROUGH the overlay (two subtitles); only re-picking cleared it.
        #expect(engine.calls.contains("setSubtitleTrack(nil)"))
    }

    @Test("direct-play: a server-preferred EXTERNAL sub wins even when the engine already auto-selected an embedded sub (the residual double-subtitle race)")
    func directPlayExternalSubtitleOverridesEnginePreselectedEmbedded() async throws {
        let reporting = StubPlaybackReporting()
        let engine = FakePlaybackEngine(id: .vlcKit, capabilities: .vlcKit)
        let resolved = PlayerFixtures.resolvedDirectPlayExternalSub()
        let vm = makePlayerVM(reporting: reporting, engine: engine, resolved: resolved)
        await vm.start(item: PlayerFixtures.movieDetail())

        // The race the prior fix left open: by the time .ready lands, VLC has ALREADY
        // discovered AND auto-selected an embedded text track, so the inventory carries it
        // and marks it selected. The server's default is still the EXTERNAL sidecar (index
        // 2). The engine's embedded pick must NOT win the `selectedSubtitleTrack == nil`
        // guard and strand the external default.
        let inventory = TrackInventory(
            audio: [AudioTrack(id: .vlc("a1"), displayName: "English", languageCode: "en")],
            subtitles: [SubtitleTrack(id: .vlc("s1"), displayName: "English (embedded)", languageCode: "en", isForced: false)],
            selectedAudioID: .vlc("a1"),
            selectedSubtitleID: .vlc("s1")
        )
        engine.push(.ready(duration: resolved.runtime!, tracks: inventory))
        try await engine.settle()

        // The external sidecar is the active selection (it overrode the engine's embedded pick)…
        #expect(vm.selectedSubtitleTrack?.id == .jellyfinStream(2))
        // …and the engine was told to drop its embedded track so it can't bleed through the overlay.
        #expect(engine.calls.contains("setSubtitleTrack(nil)"))
    }

    @Test("transcode: menus come from MediaStreams; selecting audio re-resolves at position with that index")
    func transcodeAudioSwitch() async throws {
        let reporting = StubPlaybackReporting()
        let engine = FakePlaybackEngine(id: .avKit, capabilities: .avKit)
        let resolved = PlayerFixtures.resolvedMultiTrackTranscode()

        nonisolated(unsafe) var resolveCalls: [(audio: Int?, sub: Int?, start: CMTime?)] = []
        let vm = makePlayerVM(
            reporting: reporting,
            resolve: { _, _, start, selection in
                resolveCalls.append((selection?.audioStreamIndex, selection?.subtitleStreamIndex, start))
                return resolved
            },
            engine: engine
        )

        await vm.start(item: PlayerFixtures.movieDetail())

        // Menus reflect the server's FULL track list, not the one-rendition manifest.
        #expect(vm.availableAudioTracks.count == 3)
        #expect(vm.availableSubtitleTracks.count == 2)                  // text sub + opt-in PGS burn-in entry
        #expect(vm.selectedAudioTrack?.id == .jellyfinStream(3))        // server default audio
        // The server's preference-derived default subtitle IS applied on first
        // transcode play (sidecar render, no re-resolve) — the server only sets
        // it when the user's subtitle mode/language prefs say to show one.
        #expect(vm.selectedSubtitleTrack?.id == .jellyfinStream(1))
        // displayName is the server's menuLabel: the stream's own title → the
        // language name ("Japanese" here — the fixture has no muxer title; the
        // displayTitle's codec noise is last-resort only). The truehd source
        // can't be stream-copied on the HLS transcode, so it's re-encoded; the
        // delivered codec lives in the dedicated transcodeTarget field and the
        // layout on the menu's detail line, never baked into the name.
        #expect(vm.availableAudioTracks.first?.displayName == "Japanese")
        #expect(vm.availableAudioTracks.first?.isTranscode == true)
        #expect(vm.availableAudioTracks.first?.transcodeTarget == "AAC")

        // Advance playback so the switch resumes at a real position.
        engine.push(.playing(100))
        try await engine.settle()

        // Switch to audio index 4 → re-resolve at the current position with that index.
        let track = try #require(vm.availableAudioTracks.first { $0.id == .jellyfinStream(4) })
        await vm.selectAudioTrack(track)

        #expect(resolveCalls.count == 2)
        #expect(resolveCalls.last?.audio == 4)
        #expect(resolveCalls.last?.sub == 1)                            // the auto-applied default sub rides along unchanged
        #expect(CMTimeGetSeconds(resolveCalls.last?.start ?? .zero) == 100)
        #expect(vm.selectedAudioTrack?.id == .jellyfinStream(4))
        #expect(engine.loadedAssets.count == 2)                         // engine reloaded
    }

    @Test("transcode: the PGS image sub is offered as an opt-in burn-in entry, labeled, and never auto-defaulted; the sidecar URL map still excludes it")
    func transcodeMenuIncludesBurnInImageSubtitle() async throws {
        let reporting = StubPlaybackReporting()
        let engine = FakePlaybackEngine(id: .avKit, capabilities: .avKit)
        // Point the server's own default AT the image sub — opt-in means this must
        // NOT auto-apply (a surprise re-encode on first play with no user action).
        let resolved = PlayerFixtures.resolvedMultiTrackTranscode(defaultSubtitleStreamIndex: 7)

        let vm = makePlayerVM(
            reporting: reporting,
            resolve: { _, _, _, _ in resolved },
            engine: engine
        )
        await vm.start(item: PlayerFixtures.movieDetail())

        let pgs = try #require(vm.availableSubtitleTracks.first { $0.id == .jellyfinStream(7) })
        #expect(pgs.isBurnedIn)
        // The format alone is the detail line; the menu's "Burn-in" badge (driven
        // by `isBurnedIn`) carries the consequence — same split as the audio
        // menu's codec detail + "→ AAC" transcode badge.
        #expect(pgs.detailLabel == "PGS")

        // Opt-in: the server-default pointed at the burn-in track, but nothing
        // auto-selects it.
        #expect(vm.selectedSubtitleTrack == nil)

        // Not a sidecar: PlaybackInfoService never built a VTT URL for it.
        #expect(resolved.subtitleStreamURLs[7] == nil)
    }

    @Test("transcode: picking the PGS burn-in entry re-resolves with that subtitleStreamIndex — no sidecar fetch")
    func selectingBurnInSubtitleReResolves() async throws {
        let reporting = StubPlaybackReporting()
        let engine = FakePlaybackEngine(id: .avKit, capabilities: .avKit)
        // No server default sub — isolates the explicit pick.
        let resolved = PlayerFixtures.resolvedMultiTrackTranscode(defaultSubtitleStreamIndex: nil)

        nonisolated(unsafe) var resolveCalls: [(audio: Int?, sub: Int?)] = []
        nonisolated(unsafe) var fetchedURLs: [URL] = []
        let vm = makePlayerVM(
            reporting: reporting,
            resolve: { _, _, _, selection in
                resolveCalls.append((selection?.audioStreamIndex, selection?.subtitleStreamIndex))
                return resolved
            },
            engine: engine,
            subtitleFetch: { url in fetchedURLs.append(url); return Data() }
        )
        await vm.start(item: PlayerFixtures.movieDetail())
        engine.push(.playing(100))
        try await engine.settle()

        let pgs = try #require(vm.availableSubtitleTracks.first { $0.id == .jellyfinStream(7) })
        await vm.selectSubtitleTrack(pgs)

        // The pick landed as `subtitleStreamIndex` on the re-resolve; audio rides
        // along unchanged (the server default, index 3).
        #expect(resolveCalls.count == 2)
        #expect(resolveCalls.last?.audio == 3)
        #expect(resolveCalls.last?.sub == 7)
        #expect(vm.selectedSubtitleTrack?.id == .jellyfinStream(7))
        #expect(engine.loadedAssets.count == 2)             // engine reloaded, like an audio switch
        #expect(fetchedURLs.isEmpty)                        // burn-in: no client-side sidecar fetch
        #expect(vm.subtitleRenderer == nil)                  // no overlay — the server draws it into the video
    }

    /// Both halves of the re-resolve request are load-bearing and neither is visible on screen:
    /// without the media source id the server discards the indices and rebuilds around its own
    /// defaults, and with video stream copy still on offer it can answer a burn-in with a copied
    /// stream that has no room for the picture. An audio switch wants the opposite copy answer.
    @Test("transcode: a re-resolve names its media source, and only a burn-in withdraws video stream copy")
    func reResolveCarriesSourceAndCopyIntent() async throws {
        let reporting = StubPlaybackReporting()
        let engine = FakePlaybackEngine(id: .avKit, capabilities: .avKit)
        let resolved = PlayerFixtures.resolvedMultiTrackTranscode(defaultSubtitleStreamIndex: nil)

        nonisolated(unsafe) var selections: [StreamSelection?] = []
        let vm = makePlayerVM(
            reporting: reporting,
            resolve: { _, _, _, selection in selections.append(selection); return resolved },
            engine: engine
        )
        await vm.start(item: PlayerFixtures.movieDetail())
        engine.push(.playing(100))
        try await engine.settle()

        // First play makes no claim about tracks — the server applies the user's preferences.
        #expect(selections == [nil])

        let pgs = try #require(vm.availableSubtitleTracks.first { $0.id == .jellyfinStream(7) })
        await vm.selectSubtitleTrack(pgs)
        #expect(selections.last == StreamSelection(
            mediaSourceID: "ms-1", audioStreamIndex: 3, subtitleStreamIndex: 7, burnsInSubtitle: true
        ))

        let audio5 = try #require(vm.availableAudioTracks.first { $0.id == .jellyfinStream(5) })
        await vm.selectAudioTrack(audio5)
        #expect(selections.last == StreamSelection(
            mediaSourceID: "ms-1", audioStreamIndex: 5, subtitleStreamIndex: 7, burnsInSubtitle: true
        ))
    }

    /// The silent-failure case: the server accepts the burn-in request, hands back a perfectly
    /// normal stream, and simply doesn't paint the subtitle in. Nothing on screen distinguishes
    /// that from success, so the reloaded session's own delivery method is the only witness —
    /// and a pick that didn't take must fall back like any other failed switch.
    @Test("transcode: a burn-in the server declines to encode rolls back and surfaces the failure")
    func declinedBurnInRollsBack() async throws {
        let reporting = StubPlaybackReporting()
        let engine = FakePlaybackEngine(id: .avKit, capabilities: .avKit)
        // The server answers "Hls" for the image sub — i.e. it never agreed to burn anything in.
        let resolved = PlayerFixtures.resolvedMultiTrackTranscode(
            defaultSubtitleStreamIndex: nil,
            burnInDeliveryMethod: "Hls"
        )
        let vtt = Data("WEBVTT\n\n00:00:01.000 --> 00:00:03.000\nNi hao".utf8)

        let vm = makePlayerVM(
            reporting: reporting,
            resolve: { _, _, _, _ in resolved },
            engine: engine,
            subtitleFetch: { _ in vtt }
        )
        await vm.start(item: PlayerFixtures.movieDetail())
        engine.push(.playing(100))
        try await engine.settle()

        // Start from a working text subtitle so the rollback has something to restore.
        let chinese = try #require(vm.availableSubtitleTracks.first { $0.id == .jellyfinStream(1) })
        await vm.selectSubtitleTrack(chinese)
        await vm.debugAwaitSubtitleFetch()
        #expect(vm.subtitleRenderer != nil)

        let pgs = try #require(vm.availableSubtitleTracks.first { $0.id == .jellyfinStream(7) })
        await vm.selectSubtitleTrack(pgs)
        await vm.debugAwaitSubtitleFetch()

        // The menu goes back to the track that is actually rendering, overlay included…
        #expect(vm.selectedSubtitleTrack?.id == .jellyfinStream(1))
        #expect(vm.subtitleRenderer != nil)
        // …and the same scrim any other failed switch raises offers a retry.
        let failure = try #require(vm.trackSwitchFailure)
        #expect(failure.requested == .subtitle(pgs))
        #expect(failure.fallback == .subtitle(chinese))
    }

    @Test("transcode: leaving an active burn-in for Off re-resolves with the 'no subtitle' sentinel — the server must stop re-encoding the image in")
    func leavingBurnInForOffReResolves() async throws {
        let reporting = StubPlaybackReporting()
        let engine = FakePlaybackEngine(id: .avKit, capabilities: .avKit)
        let resolved = PlayerFixtures.resolvedMultiTrackTranscode(defaultSubtitleStreamIndex: nil)

        nonisolated(unsafe) var resolveCalls: [(audio: Int?, sub: Int?)] = []
        let vm = makePlayerVM(
            reporting: reporting,
            resolve: { _, _, _, selection in
                resolveCalls.append((selection?.audioStreamIndex, selection?.subtitleStreamIndex))
                return resolved
            },
            engine: engine
        )
        await vm.start(item: PlayerFixtures.movieDetail())
        engine.push(.playing(100))
        try await engine.settle()

        // Activate the burn-in first.
        let pgs = try #require(vm.availableSubtitleTracks.first { $0.id == .jellyfinStream(7) })
        await vm.selectSubtitleTrack(pgs)
        #expect(resolveCalls.count == 2)
        #expect(engine.loadedAssets.count == 2)

        // Now turn subtitles Off — this must NOT be the cheap no-reload path: the
        // server is still burning the PGS image into the video until a fresh
        // transcode says otherwise.
        await vm.selectSubtitleTrack(nil)

        #expect(resolveCalls.count == 3)
        #expect(resolveCalls.last?.sub == -1)     // the "no subtitle" sentinel — NOT nil (which would ask for the server default again)
        #expect(resolveCalls.last?.audio == 3)    // audio rides along unchanged
        #expect(engine.loadedAssets.count == 3)   // engine reloaded
        #expect(vm.selectedSubtitleTrack == nil)
        #expect(vm.subtitleRenderer == nil)
    }

    @Test("transcode: leaving an active burn-in for a text sub re-resolves, then activates the sidecar once the reload lands")
    func leavingBurnInForTextSubReResolvesThenActivatesSidecar() async throws {
        let reporting = StubPlaybackReporting()
        let engine = FakePlaybackEngine(id: .avKit, capabilities: .avKit)
        let resolved = PlayerFixtures.resolvedMultiTrackTranscode(defaultSubtitleStreamIndex: nil)

        nonisolated(unsafe) var resolveCalls: [(audio: Int?, sub: Int?)] = []
        nonisolated(unsafe) var fetchedURLs: [URL] = []
        let vm = makePlayerVM(
            reporting: reporting,
            resolve: { _, _, _, selection in
                resolveCalls.append((selection?.audioStreamIndex, selection?.subtitleStreamIndex))
                return resolved
            },
            engine: engine,
            subtitleFetch: { url in fetchedURLs.append(url); return Data() }
        )
        await vm.start(item: PlayerFixtures.movieDetail())
        engine.push(.playing(100))
        try await engine.settle()

        // Activate the burn-in first.
        let pgs = try #require(vm.availableSubtitleTracks.first { $0.id == .jellyfinStream(7) })
        await vm.selectSubtitleTrack(pgs)
        #expect(resolveCalls.count == 2)
        #expect(fetchedURLs.isEmpty)

        // Pick the text sub — must re-resolve (stops the burn-in), THEN activate the
        // sidecar (fetch must not race the still-burning-in outgoing session).
        let text = try #require(vm.availableSubtitleTracks.first { $0.id == .jellyfinStream(1) })
        await vm.selectSubtitleTrack(text)
        await vm.debugAwaitSubtitleFetch()

        #expect(resolveCalls.count == 3)
        #expect(resolveCalls.last?.sub == 1)
        #expect(resolveCalls.last?.audio == 3)
        #expect(engine.loadedAssets.count == 3)          // engine reloaded
        #expect(vm.selectedSubtitleTrack?.id == .jellyfinStream(1))
        #expect(fetchedURLs == [try #require(resolved.subtitleStreamURLs[1])])   // fetched exactly once, AFTER the reload
    }

    @Test("transcode: Off from an active TEXT sub stays the cheap no-reload path (regression guard against always-reloading)")
    func offFromTextSubStaysNoReload() async throws {
        let reporting = StubPlaybackReporting()
        let engine = FakePlaybackEngine(id: .avKit, capabilities: .avKit)
        let resolved = PlayerFixtures.resolvedMultiTrackTranscode(defaultSubtitleStreamIndex: nil)

        nonisolated(unsafe) var resolveCalls = 0
        let vm = makePlayerVM(
            reporting: reporting,
            resolve: { _, _, _, _ in resolveCalls += 1; return resolved },
            engine: engine,
            subtitleFetch: { _ in Data() }
        )
        await vm.start(item: PlayerFixtures.movieDetail())
        engine.push(.playing(100))
        try await engine.settle()
        #expect(resolveCalls == 1)

        // Activate a TEXT sidecar — the cheap path, no reload.
        let text = try #require(vm.availableSubtitleTracks.first { $0.id == .jellyfinStream(1) })
        await vm.selectSubtitleTrack(text)
        #expect(resolveCalls == 1)
        let loadsAfterTextPick = engine.loadedAssets.count

        // Turn Off from a text sub (never a burn-in) — must NOT regress into always
        // reloading; only leaving an ACTIVE burn-in earns the re-resolve.
        await vm.selectSubtitleTrack(nil)

        #expect(resolveCalls == 1)                              // still just the initial resolve
        #expect(engine.loadedAssets.count == loadsAfterTextPick) // no reload
        #expect(vm.selectedSubtitleTrack == nil)
    }

    @Test("a burn-in switch that falls back restores the previously-active sidecar: selection AND cues re-arm")
    func burnInSwitchFailureRestoresSidecarSubtitle() async throws {
        let reporting = StubPlaybackReporting()
        let engine = FakePlaybackEngine(id: .avKit, capabilities: .avKit)
        let resolved = PlayerFixtures.resolvedMultiTrackTranscode(defaultSubtitleStreamIndex: nil)

        nonisolated(unsafe) var resolveCalls = 0
        nonisolated(unsafe) var fetchedURLs: [URL] = []
        let vm = makePlayerVM(
            reporting: reporting,
            resolve: { _, _, _, _ in
                resolveCalls += 1
                if resolveCalls == 2 { throw AppError.playback(.resourceUnavailable) }  // the burn-in switch fails
                return resolved
            },
            engine: engine,
            subtitleFetch: { url in fetchedURLs.append(url); return Data() }
        )
        await vm.start(item: PlayerFixtures.movieDetail())
        engine.push(.playing(100))
        try await engine.settle()

        // Activate the text sidecar first — the cheap path, no reload.
        let text = try #require(vm.availableSubtitleTracks.first { $0.id == .jellyfinStream(1) })
        await vm.selectSubtitleTrack(text)
        await vm.debugAwaitSubtitleFetch()
        #expect(resolveCalls == 1)
        #expect(fetchedURLs.count == 1)

        // Pick the burn-in entry — its re-resolve throws, so playback falls back to
        // the still-mounted previous stream (the text sidecar) instead of tearing down.
        let pgs = try #require(vm.availableSubtitleTracks.first { $0.id == .jellyfinStream(7) })
        await vm.selectSubtitleTrack(pgs)
        await vm.debugAwaitSubtitleFetch()

        #expect(resolveCalls == 2)
        #expect(vm.selectedSubtitleTrack?.id == .jellyfinStream(1))   // restored to the previous sidecar
        // Re-armed from the session cache, not the network: the restore is a
        // RE-selection of a track already fetched, and paying a second server-side
        // extraction for bytes we still hold is exactly what the cache exists to stop.
        #expect(fetchedURLs.count == 1)
        #expect(fetchedURLs.allSatisfy { $0 == resolved.subtitleStreamURLs[1] })
        #expect(vm.trackSwitchFailure?.requested.id == .jellyfinStream(7))
        #expect(vm.trackSwitchFailure?.fallback?.id == .jellyfinStream(1))
    }

    @Test("subs-aware transcode seek lifecycle: no sidecar → in-stream (dirty); sidecar pick on a dirty timeline → laundering reload; sidecar active → out-of-buffer re-anchors")
    func transcodeSeekGateIsSidecarAware() async throws {
        let reporting = StubPlaybackReporting()
        let engine = FakePlaybackEngine(id: .avKit, capabilities: .avKit)
        // No server-default subtitle: the point is a session with NO sidecar up, and the
        // default fixture's `defaultSubtitleStreamIndex` would auto-arm the overlay on
        // first play (`applyTranscodeDefaultSubtitle`), silently flipping the gate.
        let resolved = PlayerFixtures.resolvedMultiTrackTranscode(defaultSubtitleStreamIndex: nil)

        nonisolated(unsafe) var resolveCalls: [(start: CMTime?, audio: Int?, sub: Int?)] = []
        nonisolated(unsafe) var fetchedURLs: [URL] = []
        let vm = makePlayerVM(
            reporting: reporting,
            resolve: { _, _, start, selection in
                resolveCalls.append((start, selection?.audioStreamIndex, selection?.subtitleStreamIndex))
                return resolved
            },
            engine: engine,
            subtitleFetch: { url in fetchedURLs.append(url); return Data() }
        )

        await vm.start(item: PlayerFixtures.movieDetail())
        #expect(resolveCalls.count == 1)                         // initial resolve only
        let loadsAfterStart = engine.loadedAssets.count
        engine.push(.playing(10))
        try await engine.settle()

        // Buffer covers 0…120s: a seek to 60s is IN buffer → in-stream seek, no reload,
        // no fresh transcode — the segments are already aligned.
        engine.bufferedRange = 0...120
        await vm.seek(to: CMTime(seconds: 60, preferredTimescale: 600))
        #expect(engine.calls.contains("seek(60.0)"))
        #expect(resolveCalls.count == 1)
        #expect(engine.loadedAssets.count == loadsAfterStart)

        // OUT of buffer with NO sidecar rendering: nothing reads the clock absolutely,
        // so the seek stays IN-STREAM (old scrub feel, buffer preserved) and only marks
        // the timeline dirty — no fresh transcode, no reload.
        await vm.seek(to: CMTime(seconds: 3000, preferredTimescale: 600))
        #expect(engine.calls.contains("seek(3000.0)"))
        #expect(resolveCalls.count == 1)
        #expect(engine.loadedAssets.count == loadsAfterStart)

        // Activating a sidecar on the DIRTY timeline launders it first: one reload at
        // the current position carrying the picked index, cues fetched only after the
        // fresh item lands (absolute cues must never draw against a shifted mapping).
        let text = try #require(vm.availableSubtitleTracks.first { $0.id == .jellyfinStream(1) })
        await vm.selectSubtitleTrack(text)
        await vm.debugAwaitSubtitleFetch()
        #expect(resolveCalls.count == 2)
        #expect(resolveCalls.last?.sub == 1)
        #expect(engine.loadedAssets.count == loadsAfterStart + 1)
        #expect(fetchedURLs.count == 1)

        // The reload's fresh AVPlayerItem cleared the dirty flag: toggling the sidecar
        // off and back on now takes the cheap no-reload path.
        await vm.selectSubtitleTrack(nil)
        await vm.selectSubtitleTrack(text)
        await vm.debugAwaitSubtitleFetch()
        #expect(resolveCalls.count == 2)
        #expect(fetchedURLs.count == 1)   // re-selection is served from the session cache

        // With the sidecar UP, an out-of-buffer seek re-anchors: a fresh transcode AT
        // the target, engine reloaded, no in-stream drift seek — and the re-anchor
        // forwards the CURRENT audio + subtitle selection (a fresh transcode must not
        // silently drop the user's tracks).
        await vm.seek(to: CMTime(seconds: 5000, preferredTimescale: 600))
        #expect(resolveCalls.count == 3)
        let reanchor = try #require(resolveCalls.last)
        #expect(CMTimeGetSeconds(reanchor.start ?? .zero) == 5000)
        #expect(reanchor.audio.map(TrackID.jellyfinStream) == vm.selectedAudioTrack?.id)
        #expect(reanchor.sub.map(TrackID.jellyfinStream) == vm.selectedSubtitleTrack?.id)
        #expect(engine.loadedAssets.count == loadsAfterStart + 2)
        #expect(!engine.calls.contains("seek(5000.0)"))
    }

    @Test("""
          cancelling the scrub-commit task mid-re-anchor must not kill the reload: every scrub \
          surface cancels the in-flight commit when a newer input lands, and a reload that dies \
          with it strands the loading scrim over a paused engine with its encode job already killed
          """)
    func scrubCommitCancellationSurvivesReanchor() async throws {
        let engine = FakePlaybackEngine(id: .avKit, capabilities: .avKit)
        let resolved = PlayerFixtures.resolvedMultiTrackTranscode(defaultSubtitleStreamIndex: nil)

        // The SECOND resolve (the re-anchor) parks on a gate so the test can cancel the
        // commit task while the reload is mid-negotiation. `entered` signals the reload
        // reached the resolve; `release` lets it return. AsyncStream's `next()` is
        // cancellation-aware, so under a broken (unshielded) reload the cancel below
        // unparks it immediately — the gate can never deadlock the failure mode.
        nonisolated(unsafe) var resolveCalls = 0
        let (enteredStream, entered) = AsyncStream.makeStream(of: Void.self)
        let (releaseStream, release) = AsyncStream.makeStream(of: Void.self)
        let vm = makePlayerVM(
            resolve: { _, _, _, _ in
                resolveCalls += 1
                if resolveCalls == 2 {
                    entered.yield(())
                    var gate = releaseStream.makeAsyncIterator()
                    await gate.next()
                }
                return resolved
            },
            engine: engine
        )

        await vm.start(item: PlayerFixtures.movieDetail())
        engine.push(.playing(10))
        try await engine.settle()
        let loadsAfterStart = engine.loadedAssets.count

        // Arm the subs-aware gate: a clean-session text pick is the cheap path (no reload).
        let text = try #require(vm.availableSubtitleTracks.first { $0.id == .jellyfinStream(1) })
        await vm.selectSubtitleTrack(text)
        await vm.debugAwaitSubtitleFetch()
        #expect(resolveCalls == 1)

        // Out-of-buffer commit with the sidecar up → re-anchor reload. Run it on its own
        // task and cancel mid-resolve — what `scrubCommitTask?.cancel()` (drag/VoiceOver)
        // and `SeekCommitCoalescer.schedule` (double-tap/click burst) do to the in-flight
        // commit whenever a newer scrub arrives.
        engine.bufferedRange = 0...120
        let commit = Task {
            await vm.commitScrubSeek(to: CMTime(seconds: 5000, preferredTimescale: 600), resume: true)
        }
        var reloadEntered = enteredStream.makeAsyncIterator()
        await reloadEntered.next()
        commit.cancel()
        release.yield(())
        await commit.value

        // The reload must survive the caller's cancellation: fresh session resolved,
        // engine reloaded and playing — not abandoned into a permanent .loading scrim.
        #expect(resolveCalls == 2)
        #expect(engine.loadedAssets.count == loadsAfterStart + 1)
        engine.push(.playing(5000))
        try await engine.settle()
        #expect(vm.phase == .playing)
    }

    @Test("""
          transcode seek with a sidecar up: in-buffer stays in-stream, out-of-buffer re-anchors — \
          for a re-encode (#15845 drift) AND for a proven video copy (a mid-session ffmpeg restart \
          shifts AVPlayer's established timeline even when the copy lands on a true keyframe)
          """,
          arguments: deliveryShapes)
    func outOfBufferSeekReanchorsForEveryDelivery(delivery: TranscodeDelivery) async throws {
        let engine = FakePlaybackEngine(id: .avKit, capabilities: .avKit)
        let resolved = PlayerFixtures.resolvedMultiTrackTranscode()

        nonisolated(unsafe) var resolveCalls: [CMTime?] = []
        let vm = makePlayerVM(
            resolve: { _, _, start, _ in resolveCalls.append(start); return resolved },
            engine: engine,
            fetchDelivery: { _ in delivery },
            deliveryProbeSchedule: [.milliseconds(10)]
        )
        await vm.start(item: PlayerFixtures.movieDetail())
        #expect(resolveCalls.count == 1)
        let loadsAfterStart = engine.loadedAssets.count

        // The first .playing beat arms the delivery probe; wait for it to land.
        engine.push(.playing(10))
        try await Task.sleep(for: .milliseconds(80))
        #expect(vm.transcodeDelivery == delivery)

        // The sidecar overlay is UP (a clean-session pick — no reload), so the
        // subs-aware gate is armed: only the overlay reads the clock absolutely.
        let text = try #require(vm.availableSubtitleTracks.first { $0.id == .jellyfinStream(1) })
        await vm.selectSubtitleTrack(text)
        #expect(resolveCalls.count == 1)

        // In-buffer seek stays in-stream: those segments were downloaded under the
        // item's live timeline mapping, so they can't shift it.
        engine.bufferedRange = 0...120
        await vm.seek(to: CMTime(seconds: 60, preferredTimescale: 600))
        #expect(engine.calls.contains("seek(60.0)"))
        #expect(resolveCalls.count == 1)

        // Out-of-buffer seek re-anchors, delivery notwithstanding. Even on a proven
        // video copy the restarted segments join an AVPlayerItem whose timeline mapping
        // was established by the ORIGINAL segments — any miss (pad overshoot, keyframe
        // gap) shifts the clock under absolute sidecar cues, intermittently and by up to
        // a keyframe interval (device-confirmed 2026-07-17). A fresh item re-derives the
        // mapping, so only the re-anchor is safe.
        await vm.seek(to: CMTime(seconds: 3000, preferredTimescale: 600))
        #expect(resolveCalls.count == 2)
        #expect(CMTimeGetSeconds((resolveCalls.last ?? nil) ?? .zero) == 3000)
        #expect(engine.loadedAssets.count == loadsAfterStart + 1)   // engine reloaded
        #expect(!engine.calls.contains("seek(3000.0)"))             // no in-stream drift seek
    }

    @Test("delivery probe schedule exhausted with no result: transcodeDelivery stays nil and the exhausted flag flips")
    func deliveryProbeScheduleExhaustedStaysNil() async throws {
        let reporting = StubPlaybackReporting()
        let engine = FakePlaybackEngine(id: .avKit, capabilities: .avKit)
        let resolved = PlayerFixtures.resolvedMultiTrackTranscode()
        let vm = makePlayerVM(
            reporting: reporting,
            resolve: { _, _, _, _ in resolved },
            engine: engine,
            fetchDelivery: { _ in nil },
            deliveryProbeSchedule: [.milliseconds(5), .milliseconds(5)]
        )
        await vm.start(item: PlayerFixtures.movieDetail())
        #expect(vm.deliveryProbeExhausted == false)   // not armed until the first .playing beat

        // Both schedule entries fetch nil — the probe gives up silently, leaving the
        // seek gate conservative (nil delivery) rather than stuck reading "probing…".
        engine.push(.playing(10))
        try await Task.sleep(for: .milliseconds(80))

        #expect(vm.transcodeDelivery == nil)
        #expect(vm.deliveryProbeExhausted == true)
    }

    // MARK: - commitScrubSeek — the scrub-commit path every UI scrub now routes through

    @Test("scrub commit on direct play: in-stream engine.seek + resume — no re-anchor, byte-identical to the old path")
    func commitScrubSeekDirectPlayInStream() async throws {
        let reporting = StubPlaybackReporting()
        let engine = FakePlaybackEngine(id: .avKit, capabilities: .avKit)
        nonisolated(unsafe) var resolveCalls = 0
        let vm = makePlayerVM(
            reporting: reporting,
            resolve: { _, _, _, _ in resolveCalls += 1; return PlayerFixtures.resolved() },
            engine: engine
        )
        await vm.start(item: PlayerFixtures.movieDetail())
        let loadsAfterStart = engine.loadedAssets.count
        engine.bufferedRange = 0...120   // ignored for non-transcode: the gate exits before isBuffered

        // Resuming scrub → in-stream seek then play (the drag paused the engine to hold the frame).
        await vm.commitScrubSeek(to: CMTime(seconds: 3000, preferredTimescale: 600), resume: true)
        #expect(engine.calls.contains("seek(3000.0)"))
        #expect(engine.calls.last == "play")
        #expect(resolveCalls == 1)                              // no fresh transcode
        #expect(engine.loadedAssets.count == loadsAfterStart)   // engine not reloaded
    }

    /// The wmv/SMB VLC shape, and the whole reason the label is three-valued. While libvlc's
    /// clock is still republishing at the new offset the engine publishes its own extrapolation
    /// off the commit target: `.projected` — a guess about *landing*, but an honest statement
    /// about the PICTURE, which is already running from the target. So the bar follows it, and
    /// advances with the video for the whole hold instead of freezing at the commit for up to
    /// ten polls (which is what a single boolean forced, while the libass overlay tracked
    /// `displayClockMs` and moved anyway). A `.stale` beat in the same window is the opposite
    /// claim — the engine's clock, still reading pre-seek — and touches nothing. Neither
    /// releases: only an observed clock does.
    @Test("projected beats walk the bar forward through the hold; stale beats are ignored; observed releases")
    func scrubCommitFollowsProjectedBeatsAndIgnoresStaleOnes() async throws {
        let reporting = StubPlaybackReporting()
        let engine = FakePlaybackEngine(id: .vlcKit, capabilities: .vlcKit)
        let vm = makePlayerVM(
            reporting: reporting,
            resolve: { _, _, _, _ in PlayerFixtures.resolved() },
            engine: engine
        )
        await vm.start(item: PlayerFixtures.movieDetail())
        await vm.commitScrubSeek(to: CMTime(seconds: 3_000, preferredTimescale: 600), resume: true)

        // The seek's target echo, then the hold's extrapolations at the 500ms poll cadence —
        // `target + polls × pollMs × rate`, which is monotone and never below the target.
        var shown: [Double] = []
        for seconds in [3_000.0, 3_000.5, 3_001.0, 3_001.5] {
            engine.push(.playing(seconds, provenance: .projected))
            try await engine.settle()
            shown.append(CMTimeGetSeconds(vm.currentPosition))
        }
        #expect(shown == [3_000.0, 3_000.5, 3_001.0, 3_001.5])
        #expect(!vm.isStalled)   // a healthy hold raises no scrim

        // A clock that has not caught up with its own seek. Seven minutes back, and it moves
        // nothing: the bar stays where the projection left it.
        engine.push(.playing(600, provenance: .stale))
        try await engine.settle()
        #expect(CMTimeGetSeconds(vm.currentPosition) == 3_001.5)

        engine.push(.playing(3_002.3))
        try await engine.settle()
        #expect(CMTimeGetSeconds(vm.currentPosition) == 3_002.3)
    }

    /// The other half of the split, on the surface that pays for it. `lastPosition` is what
    /// `reportStopped` and the SMB resume point are written from, and a projection is a guess
    /// about how far the seek has run — not a place to resume. So a dismissal mid-hold records
    /// the COMMITTED target, however far the bar has walked past it, and only an observed clock
    /// moves the resume point.
    @Test("projected beats move the bar but never the resume point — that stays the commit target")
    func projectedBeatsNeverMoveTheResumePoint() async throws {
        let reporting = StubPlaybackReporting()
        let engine = FakePlaybackEngine(id: .vlcKit, capabilities: .vlcKit)
        let vm = makePlayerVM(
            reporting: reporting,
            resolve: { _, _, _, _ in PlayerFixtures.resolved() },
            engine: engine
        )
        await vm.start(item: PlayerFixtures.movieDetail())
        await vm.commitScrubSeek(to: CMTime(seconds: 3_000, preferredTimescale: 600), resume: true)

        for seconds in [3_000.0, 3_002.0, 3_004.0] {
            engine.push(.playing(seconds, provenance: .projected))
            try await engine.settle()
        }
        #expect(CMTimeGetSeconds(vm.currentPosition) == 3_004)   // the bar followed

        await vm.stop()
        // …the resume point did not: `reportStopped` carries `lastPosition`, still the commit.
        let events = await reporting.events
        #expect(events.contains(.stopped(ticks: 3_000 * 10_000_000, itemID: "movie-1")))
    }

    @Test("scrub commit on direct play while paused: seek only, no resume — a paused scrub stays paused")
    func commitScrubSeekDirectPlayPausedStaysPaused() async throws {
        let reporting = StubPlaybackReporting()
        let engine = FakePlaybackEngine(id: .avKit, capabilities: .avKit)
        let vm = makePlayerVM(
            reporting: reporting,
            resolve: { _, _, _, _ in PlayerFixtures.resolved() },
            engine: engine
        )
        await vm.start(item: PlayerFixtures.movieDetail())

        await vm.commitScrubSeek(to: CMTime(seconds: 3000, preferredTimescale: 600), resume: false)
        // load + play from start(), then the bare in-stream seek — no trailing play, no pause.
        #expect(engine.calls == ["load", "play", "seek(3000.0)"])
    }

    @Test("""
          scrub commit out of buffer re-anchors on EVERY delivery — the #15845 drift fix for a \
          re-encode, and no exemption for a proven video copy
          """,
          arguments: deliveryShapes)
    func commitScrubSeekReanchorsForEveryDelivery(delivery: TranscodeDelivery) async throws {
        let engine = FakePlaybackEngine(id: .avKit, capabilities: .avKit)
        let resolved = PlayerFixtures.resolvedMultiTrackTranscode()
        nonisolated(unsafe) var resolveCalls: [CMTime?] = []
        let vm = makePlayerVM(
            resolve: { _, _, start, _ in resolveCalls.append(start); return resolved },
            engine: engine,
            fetchDelivery: { _ in delivery },
            deliveryProbeSchedule: [.milliseconds(10)]
        )
        await vm.start(item: PlayerFixtures.movieDetail())
        let loadsAfterStart = engine.loadedAssets.count
        engine.push(.playing(10))
        try await Task.sleep(for: .milliseconds(80))
        #expect(vm.transcodeDelivery == delivery)

        // Sidecar overlay up — the subs-aware gate re-anchors for its cues.
        let text = try #require(vm.availableSubtitleTracks.first { $0.id == .jellyfinStream(1) })
        await vm.selectSubtitleTrack(text)
        #expect(resolveCalls.count == 1)

        // Out-of-buffer scrub commit → fresh transcode AT the target, not an in-stream seek.
        engine.bufferedRange = 0...120
        await vm.commitScrubSeek(to: CMTime(seconds: 3000, preferredTimescale: 600), resume: true)
        #expect(resolveCalls.count == 2)
        #expect(CMTimeGetSeconds((resolveCalls.last ?? nil) ?? .zero) == 3000)
        #expect(engine.loadedAssets.count == loadsAfterStart + 1)   // engine reloaded
        #expect(!engine.calls.contains("seek(3000.0)"))            // no in-stream drift seek
    }

    // MARK: - The seek hold — the bar shows the target from commit until the engine catches up

    /// Builds a transcode VM parked at `A` with a text sidecar up (the re-anchor gate) and
    /// a buffer that ends before any scrub target — every commit below takes the slow
    /// `reloadTranscode` path, which is the window the snap-back lives in.
    ///
    /// Engines come from an `EngineLedger`, so each one carries the id the view model asked
    /// for and a reload that RE-BUILDS shows up as a second entry — the caller's `engine`
    /// local then still points at the outgoing engine, which is a legible failure instead of
    /// one instance replaying two sessions' calls.
    private func makeReanchorVM(
        at seconds: Double,
        reporting: StubPlaybackReporting = StubPlaybackReporting(),
        seekHoldNow: @escaping @Sendable () -> ContinuousClock.Instant = { .now },
        nowPlaying: any NowPlayingUpdating = NowPlayingController(),
        resolve: @escaping PlayerViewModel.ResolveCall = { _, _, _, _ in
            PlayerFixtures.resolvedMultiTrackTranscode()
        }
    ) async throws -> (vm: PlayerViewModel, engines: EngineLedger) {
        let engines = EngineLedger()
        let vm = makePlayerVM(reporting: reporting, resolve: resolve,
                              engineFactory: { id, _ in engines.make(id) },
                              nowPlaying: nowPlaying, seekHoldNow: seekHoldNow)
        await vm.start(item: PlayerFixtures.movieDetail())
        let engine = engines.live
        engine.push(.playing(seconds))
        try await engine.settle()
        // A precondition, not an assertion: every test below reads "the bar moved OFF A",
        // which proves nothing if the fixture never parked at A. Stop here instead.
        try #require(CMTimeGetSeconds(vm.currentPosition) == seconds)

        // Sidecar overlay up: the one consumer that reads the clock absolutely, so an
        // out-of-buffer seek re-anchors instead of seeking in-stream.
        let text = try #require(vm.availableSubtitleTracks.first { $0.id == .jellyfinStream(1) })
        await vm.selectSubtitleTrack(text)
        engine.bufferedRange = 0...(seconds + 60)
        return (vm, engines)
    }

    @Test("a commit that re-anchors shows the TARGET while the reload scrim is up — never the pre-scrub position")
    func commitScrubSeekHoldsTargetThroughReanchor() async throws {
        let (vm, engines) = try await makeReanchorVM(at: 600)
        let engine = engines.live

        // The reload lands `.loading` and drops every engine beat while it runs, so this
        // returns with the OLD clock still the newest thing the engine ever published.
        await vm.commitScrubSeek(to: CMTime(seconds: 3_000, preferredTimescale: 600), resume: true)

        #expect(vm.phase == .loading)                              // still behind the scrim
        #expect(CMTimeGetSeconds(vm.currentPosition) == 3_000)     // …showing B, not A
    }

    /// The reload's own beats still carry the OLD stream's clock, which the engine labels
    /// `.stale`: its seek is unresolved, so this is the position the user seeked AWAY from.
    /// Only the first OBSERVED clock takes the bar back, and everything after it flows normally.
    @Test("stale beats at the pre-seek position hold; the first observed beat releases")
    func seekHoldReleasesOnTheFirstObservedBeat() async throws {
        let (vm, engines) = try await makeReanchorVM(at: 600)
        let engine = engines.live
        await vm.commitScrubSeek(to: CMTime(seconds: 3_000, preferredTimescale: 600), resume: true)

        for _ in 0..<4 {
            engine.push(.playing(600, provenance: .stale))
            try await engine.settle()
            #expect(CMTimeGetSeconds(vm.currentPosition) == 3_000)
        }

        engine.push(.playing(3_001))
        try await engine.settle()
        #expect(CMTimeGetSeconds(vm.currentPosition) == 3_001)

        engine.push(.playing(3_005))
        try await engine.settle()
        #expect(CMTimeGetSeconds(vm.currentPosition) == 3_005)
    }

    /// The engine is AUTHORITATIVE about an observed beat, even one that landed nowhere near
    /// the request: AVKit seeks at default (segment) tolerance and only knows that `AVPlayer`
    /// returned `finished`, and a VLC hold that gave up republishes whatever the clock really
    /// reads. Pinning the bar at an unreachable target over video that is demonstrably playing
    /// elsewhere is the worse lie — which is exactly what the old 3s drift tolerance did until
    /// it had also burned a stale-beat budget.
    @Test("an observed beat far off the target still releases — onto the engine's position",
          arguments: [600.0, 2_990.0, 3_060.0])
    func observedFarOffBeatReleasesOntoTheEnginesPosition(landing: Double) async throws {
        let (vm, engines) = try await makeReanchorVM(at: 600)
        let engine = engines.live
        await vm.commitScrubSeek(to: CMTime(seconds: 3_000, preferredTimescale: 600), resume: true)

        engine.push(.playing(landing))
        try await engine.settle()
        #expect(CMTimeGetSeconds(vm.currentPosition) == landing)
    }

    @Test("the reload's STALE buffering beats never move the bar off the target — the scrub snap-back itself")
    func seekHoldIgnoresStaleBufferingBeats() async throws {
        let (vm, engines) = try await makeReanchorVM(at: 600)
        let engine = engines.live
        await vm.commitScrubSeek(to: CMTime(seconds: 3_000, preferredTimescale: 600), resume: true)

        for _ in 0..<3 {
            engine.push(.buffering(600, provenance: .stale))
            try await engine.settle()
            #expect(CMTimeGetSeconds(vm.currentPosition) == 3_000)
        }
    }

    // MARK: - The re-anchor's first live beat

    /// A scrub committed while PAUSED re-anchors, and `commitScrubSeek` re-pauses the reload the
    /// instant it force-resumes — so that session can go its whole life without ever publishing
    /// `.playing`. Its first `.paused` beat is the only live beat it will ever have, and it has
    /// to carry both jobs: take the reload cover down (it used to sit over a rendered, healthy
    /// frame forever), and report PlaybackStart, which the reload's own `didReportStart = false`
    /// made mandatory — without it Jellyfin never learns the session exists, so no progress and
    /// no stop report land, and the position the user re-anchored to is never persisted.
    @Test("a re-anchor that lands paused lifts the cover AND reports its start")
    func pausedFirstLiveBeatAfterReloadOpensTheSession() async throws {
        let reporting = StubPlaybackReporting()
        let (vm, engines) = try await makeReanchorVM(at: 600, reporting: reporting)
        let engine = engines.live

        await vm.commitScrubSeek(to: CMTime(seconds: 3_000, preferredTimescale: 600), resume: false)
        #expect(vm.phase == .loading)   // the reload cover, over the frozen frame

        // The reloaded session's ONLY live beat: paused, at the target, and observed.
        engine.push(.paused(3_000))
        try await engine.settle()

        #expect(vm.phase == .playing, "the reload cover outlived the session that was to lift it")
        let started = (await reporting.events).filter {
            if case .start = $0 { return true } else { return false }
        }
        #expect(started.count == 2, "the re-anchored session never reported a start")

        await vm.stop()
        let stopped = (await reporting.events).filter {
            if case .stopped = $0 { return true } else { return false }
        }
        #expect(stopped.count == 2, "a session that never started can never stop")
    }

    /// The control: a `.paused` beat that is NOT a reload's first live beat changes neither the
    /// veil nor the reporting state. A cold start's veil holds no frame, and Jellyfin must not
    /// see a start for a session that has not rendered anything.
    @Test("a paused beat during a cold start neither lifts the veil nor opens the session")
    func pausedBeatDuringColdStartOpensNothing() async throws {
        let reporting = StubPlaybackReporting()
        let engine = FakePlaybackEngine(id: .avKit, capabilities: .avKit)
        let vm = makePlayerVM(reporting: reporting, engine: engine,
                              resolved: PlayerFixtures.resolvedTranscodedMKV())
        await vm.start(item: PlayerFixtures.movieDetail())

        engine.push(.paused(30))
        try await engine.settle()

        #expect(vm.phase == .loading)
        #expect(await reporting.events.isEmpty)
    }

    // MARK: - The session stamp — which media a beat is about

    /// The device-diagnosed defect in one beat, with no ordering to arrange. A re-anchor kills
    /// the outgoing encode job before the replacement resolves, so the item it left behind
    /// fails on its yanked playlist (`-19602`); that `.failed` can take its MainActor turn long
    /// after the reload finished, because the stream buffers. It carries the session the reload
    /// replaced, and that is the whole test — a flag raised for the duration of the reload was
    /// cleared on the RELOAD's timeline, while the beat is drained on the consumer's.
    @Test("a beat stamped with the session a reload replaced never reaches the view model")
    func supersededSessionBeatIsDropped() async throws {
        let (vm, engines) = try await makeReanchorVM(at: 600)
        let engine = engines.live
        let outgoing = engine.session

        await vm.commitScrubSeek(to: CMTime(seconds: 3_000, preferredTimescale: 600), resume: true)
        #expect(engine.session != outgoing, "the reload never opened a new session")

        engine.push(.failed(.assetNotPlayable), from: outgoing)
        try await engine.settle()

        #expect(vm.phase == .loading, "the dead session's failure landed on the live one")
        #expect(CMTimeGetSeconds(vm.currentPosition) == 3_000)
    }

    /// The sequence a `.loading`/`.ready` marker in the stream could not survive: the outgoing
    /// item's inventory load — spawned at its own `.readyToPlay`, and only cancelled inside the
    /// next `load()`, seconds into the re-anchor — lands `.ready` first, and the item then fails
    /// on its yanked playlist. A boundary that any `.ready` may lift is disarmed by the first
    /// beat and walked through by the second. A stamp is not liftable by the session it excludes.
    @Test("a superseded session's late .ready lifts nothing for the failure behind it")
    func supersededReadyOpensNothing() async throws {
        let (vm, engines) = try await makeReanchorVM(at: 600)
        let engine = engines.live
        let outgoing = engine.session
        await vm.commitScrubSeek(to: CMTime(seconds: 3_000, preferredTimescale: 600), resume: true)

        engine.push(.ready(duration: CMTime(seconds: 7_200, preferredTimescale: 600),
                           tracks: TrackInventory(audio: [], subtitles: [],
                                                  selectedAudioID: nil, selectedSubtitleID: nil)),
                    from: outgoing)
        engine.push(.failed(.assetNotPlayable), from: outgoing)
        try await engine.settle()

        #expect(vm.phase == .loading)
        #expect(vm.availableAudioTracks.count == 3, "the dead session's inventory replaced the menus")
    }

    /// An exit landing inside the reload's re-resolve abandons it, and the OLD session is still
    /// the one mounted. Nothing may be left armed that swallows its beats: the reload never
    /// opened a session, so the standing one is still the live one.
    @Test("an abandoned reload leaves the standing session's beats flowing")
    func abandonedReloadArmsNothing() async throws {
        nonisolated(unsafe) var callCount = 0
        nonisolated(unsafe) var triggerExit: (@MainActor () -> Void)? = nil
        let (vm, engines) = try await makeReanchorVM(at: 600, resolve: { _, _, _, _ in
            callCount += 1
            if callCount == 2 {
                await MainActor.run { triggerExit?() }
                throw AppError.playback(.resourceUnavailable)
            }
            return PlayerFixtures.resolvedMultiTrackTranscode()
        })
        let engine = engines.live
        triggerExit = { vm.beginExit() }
        let standing = engine.session

        await vm.commitScrubSeek(to: CMTime(seconds: 3_000, preferredTimescale: 600), resume: true)
        #expect(engine.session == standing, "the abandoned reload opened a session anyway")

        engine.push(.playing(640))
        try await engine.settle()
        #expect(CMTimeGetSeconds(vm.currentPosition) == 640,
                "the abandoned reload left something armed that swallows the live session's beats")
    }

    // MARK: - The reload window — from "we are reloading" to "the new session is open"

    /// Parks the RELOAD's re-resolve, so a test can act inside the window between the app
    /// committing to a reload (the standing session's encode job is already dead) and
    /// `engine.load()` opening the replacement. That window is multi-second on device, and it
    /// is where the abandoned item's own beats land.
    private final class ReloadResolveGate: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Void, Never>?
        private var isReleased = false
        private var isParked = false
        private var calls = 0

        /// True while the re-resolve is suspended here — `waitUntil`-friendly proof that the
        /// test really is inside the window, rather than a guess about scheduling.
        var parked: Bool { lock.withLock { isParked } }

        /// Parks the SECOND resolve only: the first is the fixture's own `start()`.
        func parkIfReload() async {
            let shouldPark = lock.withLock { () -> Bool in
                calls += 1
                return calls == 2 && !isReleased
            }
            guard shouldPark else { return }
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                let resumeNow = lock.withLock { () -> Bool in
                    guard !isReleased else { return true }
                    continuation = c
                    isParked = true
                    return false
                }
                if resumeNow { c.resume() }
            }
        }

        func release() {
            let due = lock.withLock { () -> CheckedContinuation<Void, Never>? in
                isReleased = true
                isParked = false
                defer { continuation = nil }
                return continuation
            }
            due?.resume()
        }
    }

    /// The device-observed decode scrim over a reload that went on to succeed. The engine's
    /// stamp only advances inside `engine.load()`, seconds after the reload killed the outgoing
    /// ffmpeg job — so for that whole window the ABANDONED item is still the active session, and
    /// its `-19602` on the yanked playlist passed the session gate and became the failure
    /// overlay. The app decides the session is over when it decides to reload; the beat has to
    /// be dropped from that moment, not from the load.
    @Test("a dead playlist's failure inside the reload window never reaches the scrim")
    func deadPlaylistFailureInsideTheReloadWindowIsDropped() async throws {
        let gate = ReloadResolveGate()
        let (vm, engines) = try await makeReanchorVM(at: 600, resolve: { _, _, _, _ in
            await gate.parkIfReload()
            return PlayerFixtures.resolvedMultiTrackTranscode()
        })
        let engine = engines.live
        let standing = engine.session

        let commit = Task {
            await vm.commitScrubSeek(to: CMTime(seconds: 3_000, preferredTimescale: 600), resume: true)
        }
        await waitUntil("the reload never reached its re-resolve") { gate.parked }

        // The item the reload left mounted, failing on the playlist whose job it just killed.
        engine.push(.failed(.assetNotPlayable), from: standing)
        try await engine.settle()
        #expect(vm.phase == .loading, "the abandoned item's failure took the reload's scrim")

        gate.release()
        await commit.value

        #expect(engine.session != standing, "the reload never opened a new session")
        #expect(vm.phase == .loading, "the reload finished behind a decode scrim it never earned")
        #expect(CMTimeGetSeconds(vm.currentPosition) == 3_000)

        // …and the reload really does complete: its own first live beat lifts the cover.
        engine.push(.playing(3_000))
        try await engine.settle()
        #expect(vm.phase == .playing)
        #expect(CMTimeGetSeconds(vm.currentPosition) == 3_000)
    }

    /// The second half of the same window, and the one the user watches: the abandoned stream
    /// keeps publishing ordinary `.observed` beats at the pre-scrub clock until its item is
    /// detached. An observed beat RELEASES the seek hold by contract, so each one dragged the
    /// dot from the destination back to where the scrub started — before the loading scrim even
    /// appeared. The beat is not the hold's to judge; it belongs to a session that is over.
    @Test("a standing-session beat inside the reload window cannot move the clock")
    func standingSessionBeatsInsideTheReloadWindowCannotMoveTheClock() async throws {
        let gate = ReloadResolveGate()
        let (vm, engines) = try await makeReanchorVM(at: 600, resolve: { _, _, _, _ in
            await gate.parkIfReload()
            return PlayerFixtures.resolvedMultiTrackTranscode()
        })
        let engine = engines.live
        let standing = engine.session

        let commit = Task {
            await vm.commitScrubSeek(to: CMTime(seconds: 3_000, preferredTimescale: 600), resume: true)
        }
        await waitUntil("the reload never reached its re-resolve") { gate.parked }

        engine.push(.playing(600, provenance: .observed), from: standing)
        try await engine.settle()

        #expect(CMTimeGetSeconds(vm.currentPosition) == 3_000,
                "the dot jumped back to where the scrub started")
        #expect(vm.seekHold != nil, "the abandoned stream's observed beat released the hold")
        #expect(vm.phase == .loading)

        gate.release()
        await commit.value
        #expect(CMTimeGetSeconds(vm.currentPosition) == 3_000)
    }

    /// The rule's other half: closing the session at the decision point is only correct because
    /// the one path that puts the OLD stream back on screen puts its session back with it.
    /// Without the restore, `fallBackAfterFailedSwitch` would resume a stream whose every beat
    /// the view model drops — a clock frozen over playing video.
    @Test("a failed re-resolve restores the standing session, and its beats move the clock again")
    func failedReloadRestoresTheStandingSession() async throws {
        nonisolated(unsafe) var calls = 0
        let (vm, engines) = try await makeReanchorVM(at: 600, resolve: { _, _, _, _ in
            calls += 1
            if calls == 2 { throw AppError.playback(.resourceUnavailable) }
            return PlayerFixtures.resolvedMultiTrackTranscode()
        })
        let engine = engines.live
        let standing = engine.session

        await vm.commitScrubSeek(to: CMTime(seconds: 3_000, preferredTimescale: 600), resume: true)
        #expect(engine.session == standing, "the failed reload opened a session anyway")
        #expect(engine.calls.last == "play", "the fallback never resumed the old stream")

        engine.push(.playing(640))
        try await engine.settle()
        #expect(CMTimeGetSeconds(vm.currentPosition) == 640,
                "the resumed stream is playing with every beat dropped")
    }

    /// A paused scrub's re-anchor is re-paused by `commitScrubSeek` and may never emit
    /// `.playing` at all. On VLC a seek committed while paused keeps projecting until playback
    /// resumes — its extrapolation freezes ON the target, which IS the correct paused
    /// position — so a `.projected` `.paused` AT the target is not a wedge, it is the contract
    /// working; AVKit's `.paused` in the same window carries the pre-seek clock, `.stale`.
    /// Neither releases. `SeekHold.watchdog` is the only thing that ever ends such a hold, and
    /// releasing there is a no-op because the beat carries the target anyway.
    @Test("held .paused beats hold — the stale pre-seek clock and the projected target alike")
    func heldPausedBeatsHold() async throws {
        let (vm, engines) = try await makeReanchorVM(at: 600)
        let engine = engines.live
        await vm.commitScrubSeek(to: CMTime(seconds: 3_000, preferredTimescale: 600), resume: false)

        for (seconds, provenance) in [(600.0, PositionProvenance.stale), (3_000.0, .projected),
                                      (600.0, .stale), (3_000.0, .projected)] {
            engine.push(.paused(seconds, provenance: provenance))
            try await engine.settle()
            #expect(CMTimeGetSeconds(vm.currentPosition) == 3_000)
        }

        // The paused landing, once the engine has actually observed it.
        engine.push(.paused(2_998))
        try await engine.settle()
        #expect(CMTimeGetSeconds(vm.currentPosition) == 2_998)
    }

    /// `AVKitEngine.seek` yields `.buffering(position: target)` BEFORE it awaits the real seek,
    /// labelled `.projected` — it carries the request, not the clock. The hold has already moved
    /// `currentPosition` to that same target, so the old position-JUMP heuristic read a delta of
    /// zero and fell back to the 400 ms stall debounce — 400 ms of bare paused glyph on every
    /// committed out-of-buffer seek. The label says "a seek is in flight" outright.
    @Test("a committed seek's own buffering echo raises the seek-fetch scrim immediately, debounce skipped")
    func heldCommitRaisesTheSeekFetchScrimOnItsOwnBufferingBeat() async throws {
        let engine = FakePlaybackEngine(id: .avKit, capabilities: .avKit)
        let vm = makePlayerVM(
            resolve: { _, _, _, _ in PlayerFixtures.resolved() },
            engine: engine
        )
        await vm.start(item: PlayerFixtures.movieDetail())
        engine.push(.playing(600))
        try await engine.settle()

        // Direct play, target outside the buffer → an in-stream `engine.seek`, which is
        // exactly the path whose pre-seek echo lands AT the target.
        engine.bufferedRange = 0...660
        await vm.commitScrubSeek(to: CMTime(seconds: 3_000, preferredTimescale: 600), resume: true)
        #expect(engine.calls.contains("seek(3000.0)"))

        engine.push(.buffering(3_000, provenance: .projected))
        try await engine.settle()
        #expect(vm.isStalled)                                    // no 400ms of bare paused glyph
        #expect(vm.showsStallScrim)
        #expect(CMTimeGetSeconds(vm.currentPosition) == 3_000)   // and the echo never released the hold
    }

    /// The half the hold could never cover: a seek the VM did not commit (a remote/PiP scrub,
    /// an engine-internal re-anchor) has no `seekHold`, and if it happens to land on the
    /// position already shown the old jump test saw a delta of zero and debounced it. The
    /// engine's own label needs neither.
    @Test("a stale buffering beat with NO hold armed raises the seek-fetch scrim immediately")
    func uncommittedSeekRaisesTheScrimWithoutAHold() async throws {
        let engine = FakePlaybackEngine(id: .avKit, capabilities: .avKit)
        let vm = makePlayerVM(resolve: { _, _, _, _ in PlayerFixtures.resolved() }, engine: engine)
        await vm.start(item: PlayerFixtures.movieDetail())
        engine.push(.playing(600))
        try await engine.settle()

        // Same position the bar already shows: zero jump, no hold — invisible to both of the
        // heuristics this replaced.
        engine.push(.buffering(600, provenance: .stale))
        try await engine.settle()
        #expect(vm.isStalled)
        #expect(vm.showsStallScrim)
    }

    /// The other side of the same line: an OBSERVED buffering beat is a mid-stream underrun (the
    /// network hiccuped where the player already is), not a fetch the user asked for — so it
    /// keeps the 400 ms debounce and a brief one never flashes the scrim.
    @Test("an observed contiguous buffering beat still goes through the 400 ms debounce")
    func observedBufferingBeatStillDebounces() async throws {
        let engine = FakePlaybackEngine(id: .avKit, capabilities: .avKit)
        let vm = makePlayerVM(resolve: { _, _, _, _ in PlayerFixtures.resolved() }, engine: engine)
        await vm.start(item: PlayerFixtures.movieDetail())
        engine.push(.playing(600))
        try await engine.settle()

        engine.push(.buffering(600))
        try await engine.settle()
        #expect(vm.isStalled == false)   // debounced, not raised

        // Settle on the condition, not a fixed margin past the 400ms debounce: a sleep that
        // clears it locally is a flake on an oversubscribed runner, and the ceiling here is a
        // hang detector rather than part of the claim.
        try await requireEventually({ vm.isStalled }, "the underrun never raised the scrim")
    }

    /// The AVKit gap the label alone cannot close. PiP and `AVPlayerViewController` scrub the
    /// AVPlayer DIRECTLY — never through `AVKitEngine.seek(to:)` — so `inFlightSeeks` stays 0
    /// and the fetch that follows is honestly `.observed`: the engine never learned a seek
    /// happened. A position discontinuity is the only evidence left, which is why the jump
    /// test stays as the OR arm beside the label.
    @Test("an observed buffering beat a jump away raises the seek-fetch scrim immediately")
    func observedBufferingBeatAfterAJumpRaisesTheScrim() async throws {
        let engine = FakePlaybackEngine(id: .avKit, capabilities: .avKit)
        let vm = makePlayerVM(resolve: { _, _, _, _ in PlayerFixtures.resolved() }, engine: engine)
        await vm.start(item: PlayerFixtures.movieDetail())
        engine.push(.playing(600))
        try await engine.settle()

        // 30s away, no hold of ours, and the engine calls it observed — a PiP scrub.
        engine.push(.buffering(630))
        try await engine.settle()
        #expect(vm.isStalled)
        #expect(vm.showsStallScrim)
    }

    /// `.stale` with NO hold armed. The label is the engine saying "this is where my own
    /// unresolved seek moved away FROM", and that is true whether or not we were the ones who
    /// asked for the seek — a PiP/remote scrub, an engine-internal re-anchor. Writing it is
    /// the scrub snap-back with the hold merely absent, which `PlaybackState`'s contract has
    /// always said ("a consumer must not show it") and the VM used to do anyway.
    @Test("a stale beat with no hold armed moves nothing; the next observed beat owns the bar")
    func staleBeatWithNoHoldIsDropped() async throws {
        let reporting = StubPlaybackReporting()
        let engine = FakePlaybackEngine(id: .avKit, capabilities: .avKit)
        let vm = makePlayerVM(reporting: reporting,
                              resolve: { _, _, _, _ in PlayerFixtures.resolved() }, engine: engine)
        await vm.start(item: PlayerFixtures.movieDetail())
        engine.push(.playing(600))
        try await engine.settle()

        engine.push(.playing(30, provenance: .stale))
        try await engine.settle()
        #expect(CMTimeGetSeconds(vm.currentPosition) == 600)

        engine.push(.playing(3_000))
        try await engine.settle()
        #expect(CMTimeGetSeconds(vm.currentPosition) == 3_000)

        await vm.stop()
        // …and the resume point never saw the stale one either.
        let events = await reporting.events
        #expect(events.contains(.stopped(ticks: 3_000 * 10_000_000, itemID: "movie-1")))
    }

    /// The watchdog exit is the one release that is NOT the engine handing the position back:
    /// it fires on whatever beat happens to arrive 20 s in, and on a wedged engine that beat
    /// carries the pre-seek clock. Ending the hold is right — nothing else can unfreeze the bar
    /// — but adopting the position it carries performs the exact snap-back the hold existed to
    /// prevent, and writes it into the resume point on the way out.
    @Test("the watchdog drops a wedged hold without adopting the stale clock it fired on")
    func watchdogReleaseNeverAdoptsTheStaleClock() async throws {
        let reporting = StubPlaybackReporting()
        nonisolated(unsafe) var now = ContinuousClock.now
        let (vm, engines) = try await makeReanchorVM(at: 600, reporting: reporting,
                                                     seekHoldNow: { now })
        let engine = engines.live

        await vm.commitScrubSeek(to: CMTime(seconds: 3_000, preferredTimescale: 600), resume: true)
        now = now.advanced(by: SeekHold.watchdog + .seconds(1))

        engine.push(.playing(0, provenance: .stale))
        try await engine.settle()
        #expect(CMTimeGetSeconds(vm.currentPosition) == 3_000)   // the bar did not snap back

        await vm.stop()
        // …and neither did the resume point, which is the half a dismissal would have persisted.
        let events = await reporting.events
        #expect(events.contains(.stopped(ticks: 3_000 * 10_000_000, itemID: "movie-1")))
    }

    /// The other half: the hold really is gone, so the engine's next observed clock owns the
    /// position outright instead of waiting for a second watchdog.
    @Test("after the watchdog release the next observed beat owns the position")
    func watchdogReleasedHoldFollowsTheNextObservedBeat() async throws {
        nonisolated(unsafe) var now = ContinuousClock.now
        let (vm, engines) = try await makeReanchorVM(at: 600, seekHoldNow: { now })
        let engine = engines.live

        await vm.commitScrubSeek(to: CMTime(seconds: 3_000, preferredTimescale: 600), resume: true)
        now = now.advanced(by: SeekHold.watchdog + .seconds(1))

        engine.push(.playing(0, provenance: .stale))
        try await engine.settle()

        engine.push(.playing(3_001))
        try await engine.settle()
        #expect(CMTimeGetSeconds(vm.currentPosition) == 3_001)
    }

    /// The no-hold route is not a safe place to relax the rule. A `.projected` beat with no
    /// hold armed is still a guess off a seek target — the VM's own watchdog drops a wedged
    /// hold at 20s while VLC keeps extrapolating to its 15s abandon cap, and PiP/remote scrubs
    /// project against seeks this VM never committed. Display-safe, so the bar follows it;
    /// never a resume point, because "how far the guess has run" is not a place anything
    /// played. `publish` used to write both here.
    @Test("a projected beat with no hold armed moves the bar but never the resume point")
    func projectedBeatWithNoHoldNeverMovesTheResumePoint() async throws {
        let reporting = StubPlaybackReporting()
        let engine = FakePlaybackEngine(id: .vlcKit, capabilities: .vlcKit)
        let vm = makePlayerVM(reporting: reporting,
                              resolve: { _, _, _, _ in PlayerFixtures.resolved() }, engine: engine)
        await vm.start(item: PlayerFixtures.movieDetail())
        engine.push(.playing(600))
        try await engine.settle()
        #expect(vm.seekHold == nil)   // the precondition: nothing here is holding

        engine.push(.playing(3_000, provenance: .projected))
        try await engine.settle()
        #expect(CMTimeGetSeconds(vm.currentPosition) == 3_000)   // the bar follows the projection

        await vm.stop()
        // …and the resume point stayed on the last clock anyone actually observed.
        let events = await reporting.events
        #expect(events.contains(.stopped(ticks: 600 * 10_000_000, itemID: "movie-1")))
    }

    /// The hold outliving the re-anchor that was supposed to honour it. A scrub committed
    /// while a track switch holds the reload gets `.abandoned` from `performTranscodeReload`,
    /// and `drainReanchorSeeks` then DROPS the target — nothing will ever play there. The hold
    /// has to go with it (as it already does on `fallBackAfterFailedSwitch`), or the switch's
    /// own reload has to spend a beat releasing a window nobody is filling.
    @Test("an abandoned re-anchor drops the hold with the target it dropped")
    func abandonedReanchorDropsTheHold() async throws {
        let gate = ResolveGate()
        let (vm, engines) = try await makeReanchorVM(at: 600, resolve: { _, _, _, _ in
            await gate.wait()
            return PlayerFixtures.resolvedMultiTrackTranscode()
        })
        let engine = engines.live
        // The switch's re-resolve parks in the gate, which is what keeps `isSwitchingTracks`
        // up while the scrub commits underneath it — the race, held open.
        await gate.arm()
        let audio = try #require(vm.availableAudioTracks.first { $0 != vm.selectedAudioTrack })
        let switching = Task { @MainActor in await vm.selectAudioTrack(audio) }
        try await requireEventually({ vm.isSwitchingTracks }, "the switch never reached the reload")

        await vm.commitScrubSeek(to: CMTime(seconds: 3_000, preferredTimescale: 600), resume: true)
        #expect(vm.seekHold == nil, "the abandoned re-anchor left its hold armed")

        await gate.open()
        await switching.value
        // The switch's own reload owns the position now: its first observed beat is adopted
        // outright, with no held target to argue with.
        engine.push(.playing(600.5))
        try await engine.settle()
        #expect(CMTimeGetSeconds(vm.currentPosition) == 600.5)
    }

    /// The watchdog needs a beat to be evaluated, and `publish` only sees position-carrying
    /// ones that survive the gates at the top of `handle` — so in exactly the windows it exists
    /// for (a track switch or a reactive reroute swallowing every beat, an engine that only
    /// ever emits `.failed`) it could never fire, and the bar stayed pinned at the target with
    /// nothing left to unpin it. Evaluated at the top of `handle` instead, on every state.
    @Test("the watchdog fires on a state that carries no position at all")
    func watchdogFiresOnANonPositionState() async throws {
        nonisolated(unsafe) var now = ContinuousClock.now
        let (vm, engines) = try await makeReanchorVM(at: 600, seekHoldNow: { now })
        let engine = engines.live
        await vm.commitScrubSeek(to: CMTime(seconds: 3_000, preferredTimescale: 600), resume: true)
        #expect(vm.seekHold != nil)

        now = now.advanced(by: SeekHold.watchdog + .seconds(1))
        engine.push(.ready(duration: CMTime(seconds: 7_200, preferredTimescale: 600), tracks: .empty))
        try await engine.settle()

        #expect(vm.seekHold == nil, "the watchdog never saw a beat it could fire on")
        #expect(CMTimeGetSeconds(vm.currentPosition) == 3_000)   // and it adopted nothing
    }

    /// A failed session emits no further position beat, so a hold left standing has nothing
    /// that could ever hand the bar back: it would ride under the error scrim and into the
    /// retry as a resume point nothing played.
    @Test("a failed phase drops the hold")
    func failedPhaseDropsTheHold() async throws {
        let (vm, engines) = try await makeReanchorVM(at: 600)
        let engine = engines.live
        await vm.commitScrubSeek(to: CMTime(seconds: 3_000, preferredTimescale: 600), resume: true)
        #expect(vm.seekHold != nil)

        engine.push(.failed(.networkStalled))
        try await engine.settle()

        #expect(vm.seekHold == nil, "the hold outlived the session it was armed in")
    }

    /// An invalid/indefinite CMTime is not a position: `CMTimeGetSeconds` gives NaN, and every
    /// consumer downstream (the bar's fraction, the remaining-time label, the resume point)
    /// inherits it. Dropped in `publish` itself, so no hold state can matter either way.
    @Test("a non-finite position never reaches currentPosition, hold or no hold",
          arguments: [CMTime.invalid, CMTime.indefinite,
                                          CMTime.positiveInfinity, CMTime.negativeInfinity])
    func nonFinitePositionsAreDropped(position: CMTime) async throws {
        let engine = FakePlaybackEngine(id: .avKit, capabilities: .avKit)
        let vm = makePlayerVM(resolve: { _, _, _, _ in PlayerFixtures.resolved() }, engine: engine)
        await vm.start(item: PlayerFixtures.movieDetail())
        engine.push(.playing(600))
        try await engine.settle()

        engine.push(.playing(position: position, duration: .fixtureDuration,
                             buffered: nil, provenance: .observed))
        try await engine.settle()
        #expect(CMTimeGetSeconds(vm.currentPosition) == 600)
    }

    /// The failed re-anchor: the re-resolve throws, `fallBackAfterFailedSwitch` resumes the
    /// OLD stream at A — so the hold's target is now a place nothing will ever play. Left
    /// armed it pins the bar at B over video running at A and leaves `lastPosition` at B as a
    /// bogus resume point. `.observed` is what the resumed OLD stream actually publishes — its
    /// seek was abandoned, not left outstanding, so its clock is its own again — and it is
    /// still the discriminator: a live hold would have released on it at 600 but so would this
    /// one, so the claim is pinned on `lastPosition` too, which a live hold would have left
    /// sitting on the unreachable target.
    @Test("a failed re-anchor drops the hold: the fallback stream's FIRST beat owns the bar again")
    func failedReanchorDropsTheHold() async throws {
        let reporting = StubPlaybackReporting()
        nonisolated(unsafe) var resolveCalls = 0
        let (vm, engines) = try await makeReanchorVM(at: 600, reporting: reporting,
                                                     resolve: { _, _, _, _ in
            resolveCalls += 1
            if resolveCalls > 1 { throw AppError.playback(.unsupportedFormat) }
            return PlayerFixtures.resolvedMultiTrackTranscode()
        })
        let engine = engines.live

        await vm.commitScrubSeek(to: CMTime(seconds: 3_000, preferredTimescale: 600), resume: true)
        #expect(resolveCalls == 2)   // the re-anchor tried, and failed

        engine.push(.playing(600))
        try await engine.settle()
        #expect(CMTimeGetSeconds(vm.currentPosition) == 600)

        await vm.stop()
        // The resume point followed the bar back: with the hold still armed it would have
        // recorded B, a place nothing ever played.
        let events = await reporting.events
        #expect(events.contains(.stopped(ticks: 600 * 10_000_000, itemID: "movie-1")))
    }

    /// The lock screen extrapolates its clock from the last `nowPlayingInfo` write, and a
    /// re-anchor drops every engine beat for seconds — so if the commit doesn't push the
    /// target itself, the Control Center clock counts on from A while the in-app bar shows B.
    @Test("the commit pushes the TARGET to Now Playing, so the lock screen and the bar agree")
    func commitPublishesTheTargetToNowPlaying() async throws {
        let nowPlaying = SpyNowPlaying()
        let (vm, engines) = try await makeReanchorVM(at: 600, nowPlaying: nowPlaying)
        let engine = engines.live
        // A precondition, not an assertion: the parked beat has to have reached Now
        // Playing at A, or "the commit moved it to B" proves nothing.
        let parked = try #require(nowPlaying.updates.last)
        try #require(CMTimeGetSeconds(parked.position) == 600)

        await vm.commitScrubSeek(to: CMTime(seconds: 3_000, preferredTimescale: 600), resume: true)

        let published = try #require(nowPlaying.updates.last)
        #expect(CMTimeGetSeconds(published.position) == 3_000)
        #expect(CMTimeGetSeconds(published.duration) == 7_200)
        await vm.stop()
    }

    @Test("re-scrubbing during a hold repoints it: the newest target shows, and only an OBSERVED beat releases")
    func seekHoldRepointsOnASecondCommit() async throws {
        let (vm, engines) = try await makeReanchorVM(at: 600)
        let engine = engines.live

        func pushStale(_ seconds: Double) async throws {
            engine.push(.playing(seconds, provenance: .stale))
            try await engine.settle()
        }

        await vm.commitScrubSeek(to: CMTime(seconds: 3_000, preferredTimescale: 600), resume: true)
        for _ in 0..<3 {
            try await pushStale(600)
            #expect(CMTimeGetSeconds(vm.currentPosition) == 3_000)
        }

        // Repoint. A fresh `SeekHold` restarts the watchdog clock, so the second commit gets
        // the whole budget rather than whatever the first one had left.
        await vm.commitScrubSeek(to: CMTime(seconds: 4_000, preferredTimescale: 600), resume: true)
        #expect(CMTimeGetSeconds(vm.currentPosition) == 4_000)

        // A beat that WOULD have satisfied the superseded target is still just the old clock.
        try await pushStale(3_001)
        #expect(CMTimeGetSeconds(vm.currentPosition) == 4_000)
        try await pushStale(600)
        #expect(CMTimeGetSeconds(vm.currentPosition) == 4_000)

        engine.push(.playing(4_001))
        try await engine.settle()
        #expect(CMTimeGetSeconds(vm.currentPosition) == 4_001)
    }

    @Test("in-buffer direct play gets the same treatment: the target shows at commit, the first observed beat releases")
    func seekHoldOnDirectPlayInStreamSeek() async throws {
        let engine = FakePlaybackEngine(id: .avKit, capabilities: .avKit)
        let vm = makePlayerVM(
            resolve: { _, _, _, _ in PlayerFixtures.resolved() },
            engine: engine
        )
        await vm.start(item: PlayerFixtures.movieDetail())
        engine.push(.playing(600))
        try await engine.settle()

        await vm.commitScrubSeek(to: CMTime(seconds: 3_000, preferredTimescale: 600), resume: true)
        #expect(engine.calls.contains("seek(3000.0)"))
        #expect(CMTimeGetSeconds(vm.currentPosition) == 3_000)

        engine.push(.playing(3_000.5))
        try await engine.settle()
        #expect(CMTimeGetSeconds(vm.currentPosition) == 3_000.5)
    }

    @Test("a restart drops the hold: the replayed session's first beat owns the position again")
    func seekHoldClearedByRestart() async throws {
        nonisolated(unsafe) var engines: [FakePlaybackEngine] = []
        let vm = makePlayerVM(
            resolve: { _, _, _, _ in PlayerFixtures.resolvedMultiTrackTranscode() },
            engineFactory: { _, _ in
                let engine = FakePlaybackEngine(id: .avKit, capabilities: .avKit)
                engines.append(engine)
                return engine
            }
        )
        await vm.start(item: PlayerFixtures.movieDetail())
        let first = try #require(engines.first)
        first.push(.playing(600))
        try await first.settle()
        let text = try #require(vm.availableSubtitleTracks.first { $0.id == .jellyfinStream(1) })
        await vm.selectSubtitleTrack(text)
        first.bufferedRange = 0...660

        await vm.commitScrubSeek(to: CMTime(seconds: 3_000, preferredTimescale: 600), resume: true)
        #expect(CMTimeGetSeconds(vm.currentPosition) == 3_000)   // hold armed and holding

        // retry() → resetForReplay → stop(), which ends the session AND the hold with it.
        await vm.retry()
        let replayed = try #require(engines.dropFirst().first)
        // A replayed stream's first beat is its own clock, with no seek outstanding: `.observed`.
        // A live hold would have pinned it at 3_000, so it is still the discriminator.
        replayed.push(.playing(5))
        try await replayed.settle()
        #expect(CMTimeGetSeconds(vm.currentPosition) == 5)       // not swallowed as a guess
    }

    @Test("scrub commit while paused on a re-encode transcode out of buffer: the force-resuming reload is re-paused")
    func commitScrubSeekReEncodePausedRepauses() async throws {
        let reporting = StubPlaybackReporting()
        let engine = FakePlaybackEngine(id: .avKit, capabilities: .avKit)
        let resolved = PlayerFixtures.resolvedMultiTrackTranscode()
        let reencode = TranscodeDelivery(
            isVideoDirect: false, isAudioDirect: true,
            videoCodec: "h264", audioCodec: "ac3",
            transcodeReasons: ["VideoCodecNotSupported"]
        )
        let vm = makePlayerVM(
            reporting: reporting,
            resolve: { _, _, _, _ in resolved },
            engine: engine,
            subtitleFetch: { _ in Data() },
            fetchDelivery: { _ in reencode },
            deliveryProbeSchedule: [.milliseconds(10)]
        )
        await vm.start(item: PlayerFixtures.movieDetail())
        let loadsAfterStart = engine.loadedAssets.count
        engine.push(.playing(10))
        try await Task.sleep(for: .milliseconds(80))

        // Sidecar overlay up so the out-of-buffer commit takes the re-anchor branch.
        let text = try #require(vm.availableSubtitleTracks.first { $0.id == .jellyfinStream(1) })
        await vm.selectSubtitleTrack(text)

        // The reload's loadAndPlay force-resumes; a scrub that began PAUSED (resume:false)
        // must be re-paused, so the last command the engine sees is a pause.
        engine.bufferedRange = 0...120
        await vm.commitScrubSeek(to: CMTime(seconds: 3000, preferredTimescale: 600), resume: false)
        #expect(engine.loadedAssets.count == loadsAfterStart + 1)   // re-anchored (engine reloaded)
        #expect(engine.calls.contains("play"))                      // reload force-resumed
        #expect(engine.calls.last == "pause")                       // …then re-paused for the paused scrub
    }

    @Test("scrub commit supersession: a second out-of-buffer re-anchor issued while the first is still resolving wins — newest target, no stale strand")
    func commitScrubSeekReanchorSupersedesNewestWins() async throws {
        let reporting = StubPlaybackReporting()
        let engine = FakePlaybackEngine(id: .avKit, capabilities: .avKit)
        let resolved = PlayerFixtures.resolvedMultiTrackTranscode()
        let reencode = TranscodeDelivery(
            isVideoDirect: false, isAudioDirect: true,
            videoCodec: "h264", audioCodec: "ac3",
            transcodeReasons: ["VideoCodecNotSupported"]
        )

        // Gate the FIRST re-anchor's resolve (target A = 3000s) open until the SECOND
        // commitScrubSeek (target B = 5000s) has run and superseded it. Deterministic —
        // NO Task.sleep: `firstReanchorEntered` signals the drain is parked mid-reload, and
        // `releaseFirstReanchor` unparks resolve #A only after B has enqueued behind it.
        let firstReanchorEntered = AsyncStream<Void>.makeStream()
        let releaseFirstReanchor = AsyncStream<Void>.makeStream()
        nonisolated(unsafe) var resolveStarts: [CMTime?] = []
        let vm = makePlayerVM(
            reporting: reporting,
            resolve: { _, _, start, _ in
                resolveStarts.append(start)
                // Only the target-A re-anchor parks; the initial start (nil) and the
                // target-B re-anchor pass straight through.
                if let start, CMTimeGetSeconds(start) == 3000 {
                    firstReanchorEntered.continuation.yield(())
                    firstReanchorEntered.continuation.finish()
                    for await _ in releaseFirstReanchor.stream { break }   // park until released
                }
                return resolved
            },
            engine: engine,
            subtitleFetch: { _ in Data() },
            fetchDelivery: { _ in reencode },
            deliveryProbeSchedule: [.milliseconds(10)]
        )
        await vm.start(item: PlayerFixtures.movieDetail())
        let loadsAfterStart = engine.loadedAssets.count
        engine.push(.playing(10))
        try await Task.sleep(for: .milliseconds(80))
        #expect(vm.transcodeDelivery?.isVideoDirect == false)

        // Sidecar overlay up — out-of-buffer targets take the re-anchor branch.
        let text = try #require(vm.availableSubtitleTracks.first { $0.id == .jellyfinStream(1) })
        await vm.selectSubtitleTrack(text)

        // Both targets are outside the buffer → both take the re-anchor branch.
        engine.bufferedRange = 0...120
        let targetA = CMTime(seconds: 3000, preferredTimescale: 600)
        let targetB = CMTime(seconds: 5000, preferredTimescale: 600)

        // First commit runs on its own MainActor task; it parks inside resolve(A) with
        // `isReanchoring == true`, holding the single-flight drain open.
        let first = Task { @MainActor in await vm.commitScrubSeek(to: targetA, resume: true) }
        for await _ in firstReanchorEntered.stream { break }   // wait until the drain is parked

        // Second commit lands WHILE the first re-anchor is still resolving. seek(B) sees
        // `isReanchoring` and hands B to the drain's pending slot instead of an engine.seek
        // — it must supersede A, not strand it. This returns immediately (no reload here).
        await vm.commitScrubSeek(to: targetB, resume: true)

        // Unpark resolve(A); the drain finishes A's reload, then loops onto the newer B.
        releaseFirstReanchor.continuation.yield(())
        releaseFirstReanchor.continuation.finish()
        await first.value

        // (a) The drain SETTLED on the newest target: the last resolve/reload is at B, not A.
        #expect(CMTimeGetSeconds((resolveStarts.last ?? nil) ?? .zero) == 5000)
        #expect(resolveStarts.compactMap { $0.map(CMTimeGetSeconds) } == [3000, 5000])   // A first, then B
        // (b) Engine outcome is consistent with B and never stranded on A: two clean
        // reloads (A then B) and NO in-stream drift seek to either stale target — the
        // landing target lives in the resolve `start` arg asserted above (the fake resolve
        // returns a fixed asset, so loadedAssets can't re-prove it).
        #expect(engine.loadedAssets.count == loadsAfterStart + 2)
        #expect(!engine.calls.contains("seek(3000.0)"))
        #expect(!engine.calls.contains("seek(5000.0)"))
        // (c) resume:true on BOTH commits → the final reload force-resumes and nothing
        // re-pauses it: playback ends playing, not stranded paused.
        #expect(engine.calls.last == "play")
    }

    @Test("re-anchor resolve wedged past the deadline: the reload falls back to the still-mounted stream instead of a stuck 'Buffering' scrim")
    func reanchorResolveDeadlineFallsBack() async throws {
        let reporting = StubPlaybackReporting()
        let engine = FakePlaybackEngine(id: .avKit, capabilities: .avKit)
        let resolved = PlayerFixtures.resolvedMultiTrackTranscode()

        nonisolated(unsafe) var resolveCalls = 0
        let vm = makePlayerVM(
            reporting: reporting,
            resolve: { _, _, _, _ in
                resolveCalls += 1
                // The re-anchor's negotiation wedges (dead server mid-session). The
                // deadline must cancel this — the sleep is cancellation-aware, so the
                // test never actually waits it out.
                if resolveCalls >= 2 { try await Task.sleep(for: .seconds(60)) }
                return resolved
            },
            engine: engine,
            subtitleFetch: { _ in Data() },
            reloadResolveDeadline: .milliseconds(80)
        )
        await vm.start(item: PlayerFixtures.movieDetail())
        let loadsAfterStart = engine.loadedAssets.count
        engine.push(.playing(10))
        try await engine.settle()

        // Sidecar overlay up so the out-of-buffer commit takes the re-anchor branch.
        let text = try #require(vm.availableSubtitleTracks.first { $0.id == .jellyfinStream(1) })
        await vm.selectSubtitleTrack(text)

        // The scrub's re-anchor hits the wedged resolve; the deadline fires and the
        // reload falls back: the old stream (still mounted, just paused for the swap)
        // resumes, no engine reload happens, and the sidecar selection survives. The
        // next scrub simply retries — nothing is stuck.
        engine.bufferedRange = 0...120
        await vm.commitScrubSeek(to: CMTime(seconds: 3000, preferredTimescale: 600), resume: true)

        #expect(resolveCalls == 2)                                // re-anchor attempted once
        #expect(engine.loadedAssets.count == loadsAfterStart)     // no reload landed
        #expect(engine.calls.last == "play")                      // fallback resumed the old stream
        #expect(vm.selectedSubtitleTrack?.id == .jellyfinStream(1))
        #expect(!engine.calls.contains("seek(3000.0)"))           // and no drift seek slipped through
    }

    @Test("an engine-reusing reload freezes the surface's last frame; the swapped-in session's first .playing beat releases it exactly once")
    func reloadFreezesSurfaceUntilFirstLiveBeat() async throws {
        let reporting = StubPlaybackReporting()
        let engine = FakePlaybackEngine(id: .avKit, capabilities: .avKit)
        let resolved = PlayerFixtures.resolvedMultiTrackTranscode()
        let vm = makePlayerVM(
            reporting: reporting,
            resolve: { _, _, _, _ in resolved },
            engine: engine,
            subtitleFetch: { _ in Data() }
        )
        nonisolated(unsafe) var freezeCalls = 0
        nonisolated(unsafe) var unfreezeCalls = 0
        vm.freezeSurfaceAction = { freezeCalls += 1 }
        vm.unfreezeSurfaceAction = { unfreezeCalls += 1 }

        await vm.start(item: PlayerFixtures.movieDetail())
        engine.push(.playing(10))
        try await engine.settle()
        // Ordinary beats never touch the host (`surfaceFrozen` gates the unfreeze side).
        #expect(freezeCalls == 0)
        #expect(unfreezeCalls == 0)

        // The fixture's server-default subtitle auto-armed the sidecar, so an
        // out-of-buffer scrub re-anchors — the reload must freeze BEFORE the swap.
        engine.bufferedRange = 0...120
        await vm.commitScrubSeek(to: CMTime(seconds: 3000, preferredTimescale: 600), resume: true)
        #expect(freezeCalls == 1)
        #expect(unfreezeCalls == 0)   // held until the new session actually renders

        // First live beat of the swapped-in session releases the frame — once.
        engine.push(.playing(3000))
        try await engine.settle()
        #expect(unfreezeCalls == 1)
        engine.push(.playing(3001))
        try await engine.settle()
        #expect(unfreezeCalls == 1)
    }

    @Test("a PAUSED scrub's re-anchor releases the held frame on the .paused beat — the re-paused session never emits .playing")
    func pausedReanchorReleasesFrozenFrameOnPausedBeat() async throws {
        let reporting = StubPlaybackReporting()
        let engine = FakePlaybackEngine(id: .avKit, capabilities: .avKit)
        let resolved = PlayerFixtures.resolvedMultiTrackTranscode()
        let vm = makePlayerVM(
            reporting: reporting,
            resolve: { _, _, _, _ in resolved },
            engine: engine,
            subtitleFetch: { _ in Data() }
        )
        nonisolated(unsafe) var freezeCalls = 0
        nonisolated(unsafe) var unfreezeCalls = 0
        vm.freezeSurfaceAction = { freezeCalls += 1 }
        vm.unfreezeSurfaceAction = { unfreezeCalls += 1 }

        await vm.start(item: PlayerFixtures.movieDetail())
        engine.push(.playing(10))
        try await engine.settle()

        engine.bufferedRange = 0...120
        await vm.commitScrubSeek(to: CMTime(seconds: 3000, preferredTimescale: 600), resume: false)
        #expect(freezeCalls == 1)
        #expect(unfreezeCalls == 0)

        // The re-paused player renders the target frame without ever playing —
        // the .paused beat is the "surface is live again" signal here.
        engine.push(.paused(3000))
        try await engine.settle()
        #expect(unfreezeCalls == 1)
    }

    @Test("delivery re-fetches after a track switch — burn-in can flip a video-copy remux to a re-encode")
    func deliveryRefetchesOnTrackSwitch() async throws {
        let reporting = StubPlaybackReporting()
        let engine = FakePlaybackEngine(id: .avKit, capabilities: .avKit)
        let resolved = PlayerFixtures.resolvedMultiTrackTranscode()
        // First session remuxes (video copy); the post-switch session re-encodes it.
        let deliveries = [
            TranscodeDelivery(isVideoDirect: true, isAudioDirect: false,
                              videoCodec: "hevc", audioCodec: "aac", transcodeReasons: []),
            TranscodeDelivery(isVideoDirect: false, isAudioDirect: false,
                              videoCodec: "hevc", audioCodec: "aac",
                              transcodeReasons: ["SubtitleCodecNotSupported"]),
        ]
        nonisolated(unsafe) var deliveryCalls = 0
        let vm = makePlayerVM(
            reporting: reporting,
            resolve: { _, _, _, _ in resolved },
            engine: engine,
            fetchDelivery: { _ in
                defer { deliveryCalls += 1 }
                return deliveries[min(deliveryCalls, deliveries.count - 1)]
            },
            deliveryProbeSchedule: [.milliseconds(10)]
        )
        await vm.start(item: PlayerFixtures.movieDetail())

        // First session's probe lands the remux verdict.
        engine.push(.playing(100))
        try await Task.sleep(for: .milliseconds(80))
        #expect(vm.transcodeDelivery?.isVideoDirect == true)

        // Switch audio → the reused engine reloads a fresh session (didReportStart resets).
        let audio4 = try #require(vm.availableAudioTracks.first { $0.id == .jellyfinStream(4) })
        await vm.selectAudioTrack(audio4)
        // Stale delivery is cleared the moment the new session's probe arms.
        #expect(vm.transcodeDelivery == nil)

        // The new session's first .playing beat re-arms the probe → the fresh verdict.
        engine.push(.playing(101))
        try await Task.sleep(for: .milliseconds(80))
        #expect(vm.transcodeDelivery?.isVideoDirect == false)
    }

    @Test("transcode resumes by client seek: the asset carries the offset and a switch resumes at the live position (no origin double-count)")
    func transcodeResumeSeeksClientSide() async throws {
        let reporting = StubPlaybackReporting()
        let engine = FakePlaybackEngine(id: .avKit, capabilities: .avKit)
        // Resolve resuming at 600s. Jellyfin's transcode is a full-timeline playlist
        // that ignores StartTimeTicks for the offset, so the engine must SEEK there.
        let resolved = PlayerFixtures.resolvedMultiTrackTranscode(
            startTime: CMTime(seconds: 600, preferredTimescale: 600)
        )

        nonisolated(unsafe) var resolveStarts: [CMTime?] = []
        let vm = makePlayerVM(
            reporting: reporting,
            resolve: { _, _, start, _ in resolveStarts.append(start); return resolved },
            engine: engine
        )
        await vm.start(item: PlayerFixtures.movieDetail())

        // The transcode asset must carry the resume offset so the engine seeks to it
        // — was nil, so every transcode (incl. resume) restarted at 0:00.
        #expect(CMTimeGetSeconds(engine.loadedAssets.first?.startTime ?? .invalid) == 600)

        // currentPosition is absolute media time (the engine seeked); a switch must
        // resume THERE — not origin(600) + position(900) = 1500.
        engine.push(.playing(900))
        try await engine.settle()

        let audio4 = try #require(vm.availableAudioTracks.first { $0.id == .jellyfinStream(4) })
        await vm.selectAudioTrack(audio4)

        // `.last` of [CMTime?] is doubly-optional — flatten before comparing.
        let switchStart = try #require(resolveStarts.last ?? nil)
        #expect(CMTimeGetSeconds(switchStart) == 900)
    }

    @Test("transcode audio switch reuses the engine instance — the video surface isn't torn down to black")
    func transcodeSwitchReusesEngine() async throws {
        let reporting = StubPlaybackReporting()
        let resolved = PlayerFixtures.resolvedMultiTrackTranscode()

        // A factory that builds a DISTINCT engine per call, so a re-creation would
        // bump the count and break identity — the assertions below prove reuse.
        nonisolated(unsafe) var createdEngines: [FakePlaybackEngine] = []
        let vm = makePlayerVM(
            reporting: reporting,
            resolve: { _, _, _, _ in resolved },
            engineFactory: { _, _ in
                let engine = FakePlaybackEngine(id: .avKit, capabilities: .avKit)
                createdEngines.append(engine)
                return engine
            }
        )
        await vm.start(item: PlayerFixtures.movieDetail())
        let engineAfterStart = try #require(vm.engine as? FakePlaybackEngine)
        #expect(createdEngines.count == 1)

        createdEngines[0].push(.playing(100))
        try await createdEngines[0].settle()

        // Switch audio → the engine is RELOADED in place, not recreated, so its
        // AVPlayer layer stays mounted (no black teardown between old + new streams).
        let audio4 = try #require(vm.availableAudioTracks.first { $0.id == .jellyfinStream(4) })
        await vm.selectAudioTrack(audio4)

        #expect(createdEngines.count == 1)                                       // factory NOT called again
        #expect((vm.engine as? FakePlaybackEngine) === engineAfterStart)         // same instance, reloaded
        #expect(engineAfterStart.loadedAssets.count == 2)                        // start load + switch reload
        #expect(!engineAfterStart.calls.contains("teardown"))                    // never torn down across the swap
        #expect(engineAfterStart.calls.contains("silence"))                      // frame frozen + audio killed at selection
    }

    /// libvlc instance arguments are fixed when the player is built, so the reload guard
    /// has to compare them — but only for the engine that is actually built with them.
    /// AVFoundation draws its own subtitles and the factory drops the arguments for it, so
    /// a transcode reload must keep reusing the AVKit engine even across a restyle:
    /// rebuilding would tear down the AVPlayer, and with it the held frame the reuse path
    /// exists to preserve.
    @Test("a transcode reload keeps its AVKit engine across a subtitle restyle",
          arguments: [SubtitleFontDesign.sansSerif, .serif])
    func transcodeReloadKeepsTheEngineAcrossARestyle(switchedTo design: SubtitleFontDesign) async throws {
        let resolved = PlayerFixtures.resolvedMultiTrackTranscode()

        nonisolated(unsafe) var style = SubtitleStyle.standard.with { $0.fontDesign = .sansSerif }
        nonisolated(unsafe) var createdEngines: [FakePlaybackEngine] = []
        nonisolated(unsafe) var factoryOptions: [[String]?] = []
        let vm = makePlayerVM(
            reporting: StubPlaybackReporting(),
            resolve: { _, _, _, _ in resolved },
            engineFactory: { _, options in
                factoryOptions.append(options)
                let engine = FakePlaybackEngine(id: .avKit, capabilities: .avKit)
                createdEngines.append(engine)
                return engine
            },
            subtitleStyle: { style }
        )
        await vm.start(item: PlayerFixtures.movieDetail())
        let engineAfterStart = try #require(vm.engine as? FakePlaybackEngine)
        #expect(createdEngines.count == 1)
        // Nothing VLC-shaped is handed to an engine that cannot read it.
        #expect(factoryOptions.first ?? nil == nil)

        createdEngines[0].push(.playing(100))
        try await createdEngines[0].settle()

        style = SubtitleStyle.standard.with { $0.fontDesign = design }
        let audio4 = try #require(vm.availableAudioTracks.first { $0.id == .jellyfinStream(4) })
        await vm.selectAudioTrack(audio4)

        #expect(createdEngines.count == 1)
        #expect((vm.engine as? FakePlaybackEngine) === engineAfterStart)
    }

    /// A view model whose SECOND resolve answers with a direct-play VC-1 MKV. The server
    /// picks the delivery per request, so a track switch's re-resolve can come back with a
    /// stream the engine in hand cannot play — VC-1 routes to VLC, the transcode it
    /// replaces ran on AVKit — and the reload must BUILD an engine instead of reloading
    /// the live one. The rebuild branch every other reload test deliberately avoids.
    private func makeEngineRebuildVM() -> (vm: PlayerViewModel, engines: EngineLedger) {
        let ledger = EngineLedger()
        // No server default subtitle: nothing may auto-apply between the two resolves the
        // test counts.
        let transcode = PlayerFixtures.resolvedMultiTrackTranscode(defaultSubtitleStreamIndex: nil)
        nonisolated(unsafe) var resolveCount = 0
        let vm = makePlayerVM(
            resolve: { _, _, _, _ in
                resolveCount += 1
                return resolveCount == 1 ? transcode : PlayerFixtures.resolvedVC1MKV()
            },
            engineFactory: { id, _ in ledger.make(id) }
        )
        return (vm, ledger)
    }

    /// Drives `makeEngineRebuildVM` to the point of the switch: the session is playing on
    /// the AVKit transcode engine and the VC-1 audio track is picked out, so the caller only
    /// has to trigger the switch that rebuilds.
    private func startEngineRebuildVM() async throws -> (
        vm: PlayerViewModel, engines: EngineLedger,
        outgoing: FakePlaybackEngine, switchTo: AudioTrack
    ) {
        let (vm, engines) = makeEngineRebuildVM()
        await vm.start(item: PlayerFixtures.movieDetail())
        let outgoing = try #require(vm.engine as? FakePlaybackEngine)
        try #require(outgoing.id == .avKit)
        outgoing.push(.playing(100))
        try await outgoing.settle()
        let audio4 = try #require(vm.availableAudioTracks.first { $0.id == .jellyfinStream(4) })
        return (vm, engines, outgoing, audio4)
    }

    @Test("a reload that must change engines retires the outgoing engine")
    func engineRebuildRetiresTheOutgoingEngine() async throws {
        let (vm, engines, outgoing, audio4) = try await startEngineRebuildVM()
        await vm.selectAudioTrack(audio4)

        // A new engine, and the old one really retired: a bare reference swap would leave
        // it decoding (VLC keeps its audio running), its progress task ticking and its
        // delegate wired — two streams playing at once.
        #expect(engines.count == 2)
        let incoming = try #require(vm.engine as? FakePlaybackEngine)
        #expect(incoming !== outgoing)
        #expect(incoming.id == .vlcKit)
        #expect(incoming.calls.contains("load"))
        #expect(incoming.calls.contains("play"))
        // The audio cut leads the swap and the teardown follows it — the whole point of
        // splitting them: silence is owed to the user NOW, the teardown is owed to nobody.
        await waitUntil { outgoing.calls.contains("teardown") }
        let cut = try #require(outgoing.calls.firstIndex(of: "endAudio"))
        let torn = try #require(outgoing.calls.firstIndex(of: "teardown"))
        #expect(cut < torn)
    }

    /// The outgoing engine's audio must be dead before the replacement opens its own: two
    /// decoders feeding one output is the audible defect a rebuild has to avoid, and it is
    /// the ONLY part of retiring an engine the swap is allowed to wait for.
    @Test("the outgoing engine's audio is cut before the incoming engine loads")
    func rebuildCutsOutgoingAudioBeforeTheIncomingLoads() async throws {
        let (vm, engines, outgoing, audio4) = try await startEngineRebuildVM()
        outgoing.holdEndAudio()

        let switching = Task { await vm.selectAudioTrack(audio4) }
        await waitUntil { outgoing.hasParkedEndAudio }

        // Parked INSIDE the swap: the cut is recorded, the replacement has not loaded, and
        // the slot still holds the outgoing engine — never nil, so the video host stays
        // mounted over the frozen frame for the whole rebuild.
        #expect(outgoing.calls.contains("endAudio"))
        #expect(vm.engine === outgoing)
        #expect(!engines.live.calls.contains("load"))

        outgoing.releaseEndAudio()
        await switching.value

        let incoming = try #require(vm.engine as? FakePlaybackEngine)
        #expect(incoming !== outgoing)
        #expect(incoming.calls.first == "load")
    }

    /// The retirement is a tracked background task, not a step of the swap: the picture
    /// comes back as soon as the replacement is loaded, however long VLC takes to wind the
    /// old player down (multi-second on a parked SMB read). `stop()` is what pays that debt.
    @Test("a parked teardown holds up neither the swap nor the view model — but stop() waits for it")
    func aParkedTeardownDelaysOnlyTheDrain() async throws {
        let (vm, engines, outgoing, audio4) = try await startEngineRebuildVM()
        outgoing.holdTeardown()

        await vm.selectAudioTrack(audio4)

        // The switch returned with the replacement live and playing…
        #expect(engines.count == 2)
        let incoming = try #require(vm.engine as? FakePlaybackEngine)
        #expect(incoming !== outgoing)
        #expect(incoming.calls.contains("play"))
        // …while the outgoing teardown is still parked.
        await waitUntil { outgoing.hasParkedTeardown }
        #expect(outgoing.hasParkedTeardown)

        // Session end drains it: `stop()` cannot return while a retirement is outstanding,
        // or a teardown would outlive the session that started it.
        nonisolated(unsafe) var stopReturned = false
        let stopping = Task { await vm.stop(); stopReturned = true }
        for _ in 0..<50 { await Task.yield() }
        #expect(stopReturned == false, "stop() returned with a teardown still in flight")

        outgoing.releaseTeardown()
        await stopping.value
        #expect(vm.engine == nil)
        #expect(outgoing.calls.contains("teardown"))
        #expect(incoming.calls.contains("teardown"))
    }

    /// The transport intent the user expressed DURING the rebuild owns the session that
    /// comes out of it. The reload's own `play()` is mechanical — a track switch resumes
    /// because it must — so a pause that landed while the engine was being replaced has to
    /// survive it, or a lock-screen pause mid-switch comes back playing.
    @Test("a pause issued during the rebuild is honored by the rebuilt engine")
    func aPauseDuringTheRebuildSurvivesIt() async throws {
        let (vm, _, outgoing, audio4) = try await startEngineRebuildVM()
        outgoing.holdEndAudio()

        let switching = Task { await vm.selectAudioTrack(audio4) }
        await waitUntil { outgoing.hasParkedEndAudio }

        // The lock screen's pause, landing inside the swap. It is accepted because the slot
        // is never empty: a nil engine here makes `setPlaying` return without even recording
        // the intent, and the rebuilt engine then comes up playing against it.
        vm.setPlaying(false)
        #expect(vm.desiredPlaying == false)

        outgoing.releaseEndAudio()
        await switching.value

        let incoming = try #require(vm.engine as? FakePlaybackEngine)
        #expect(vm.desiredPlaying == false)
        #expect(incoming.calls.last == "pause")
    }

    /// The race the identity guard in `handle(_:from:)` exists for: a beat already pulled
    /// from the outgoing engine's stream, suspended on its hop to the view model while the
    /// replacement is installed. Cancelling a subscription cannot recall a state already in
    /// flight, so nothing but the guard stops the dead session from writing its clock (and
    /// its phase) over the live one's.
    @Test("a beat from the replaced engine never reaches the view model's state")
    func replacedEngineBeatsAreIgnored() async throws {
        let (vm, engines, outgoing, audio4) = try await startEngineRebuildVM()

        // In flight before the switch, held between the stream and the consumer.
        outgoing.holdBeats()
        let delivered = outgoing.deliveredBeats
        outgoing.push(.playing(4_242))
        await waitUntil { outgoing.hasParkedBeat }

        await vm.selectAudioTrack(audio4)
        #expect(engines.count == 2)

        // The new session owns the bar.
        let incoming = try #require(vm.engine as? FakePlaybackEngine)
        incoming.push(.playing(7))
        try await incoming.settle()
        #expect(CMTimeGetSeconds(vm.currentPosition) == 7)

        // Now let the replaced engine's beat land. `settle()` can't be the barrier here —
        // the outgoing subscription is cancelled, so it never comes back for another
        // element and its processed count can never advance again; delivery is what is
        // observable, and the yields cover the handler's hop after it.
        outgoing.releaseBeats()
        await waitUntil { outgoing.deliveredBeats > delivered }
        for _ in 0..<50 { await Task.yield() }

        #expect(CMTimeGetSeconds(vm.currentPosition) == 7)
        #expect(vm.phase == .playing)
    }

    @Test("transcode: subtitle selection is isolated — an explicit sub survives an audio switch; none stays none")
    func transcodeSubtitleIsolation() async throws {
        let reporting = StubPlaybackReporting()
        let engine = FakePlaybackEngine(id: .avKit, capabilities: .avKit)
        // No server default subtitle: this test is about EXPLICIT selection
        // isolation, so nothing may be auto-applied at start.
        let resolved = PlayerFixtures.resolvedMultiTrackTranscode(defaultSubtitleStreamIndex: nil)

        nonisolated(unsafe) var resolveCalls: [(audio: Int?, sub: Int?)] = []
        let vm = makePlayerVM(
            reporting: reporting,
            resolve: { _, _, _, selection in
                resolveCalls.append((selection?.audioStreamIndex, selection?.subtitleStreamIndex))
                return resolved
            },
            engine: engine
        )
        await vm.start(item: PlayerFixtures.movieDetail())
        engine.push(.playing(50))
        try await engine.settle()

        // Nothing auto-selected at start (the server surfaced no default sub).
        #expect(vm.selectedSubtitleTrack == nil)
        #expect(resolveCalls.first?.sub == nil)

        // User turns on the Chinese text subtitle (index 1). Client-side rendering
        // fetches a sidecar VTT — NO re-resolve / re-transcode on a sub toggle.
        let resolvesBeforeSub = resolveCalls.count
        let chinese = try #require(vm.availableSubtitleTracks.first { $0.id == .jellyfinStream(1) })
        await vm.selectSubtitleTrack(chinese)
        #expect(resolveCalls.count == resolvesBeforeSub)
        #expect(vm.selectedSubtitleTrack?.id == .jellyfinStream(1))

        // Switch audio → the subtitle (1) must be carried unchanged; audio becomes 4.
        let audio4 = try #require(vm.availableAudioTracks.first { $0.id == .jellyfinStream(4) })
        await vm.selectAudioTrack(audio4)
        #expect(resolveCalls.last?.audio == 4)
        #expect(resolveCalls.last?.sub == 1)            // subtitle isolated — preserved across the audio switch
        #expect(vm.selectedSubtitleTrack?.id == .jellyfinStream(1))
    }

    @Test("transcode: picking a text subtitle fetches + loads the sidecar into the client renderer (no re-resolve); Off clears it")
    func transcodeSidecarSubtitle() async throws {
        let reporting = StubPlaybackReporting()
        let engine = FakePlaybackEngine(id: .avKit, capabilities: .avKit)
        let resolved = PlayerFixtures.resolvedMultiTrackTranscode()
        let vtt = Data("WEBVTT\n\n00:00:01.000 --> 00:00:03.000\nNi hao".utf8)

        nonisolated(unsafe) var resolveCount = 0
        nonisolated(unsafe) var fetchedURLs: [URL] = []
        let vm = makePlayerVM(
            reporting: reporting,
            resolve: { _, _, _, _ in resolveCount += 1; return resolved },
            engine: engine,
            subtitleFetch: { url in fetchedURLs.append(url); return vtt }
        )
        await vm.start(item: PlayerFixtures.movieDetail())
        let resolvesAfterStart = resolveCount

        // Pick the Chinese text sub → fetch + parse the sidecar; no re-transcode.
        let chinese = try #require(vm.availableSubtitleTracks.first { $0.id == .jellyfinStream(1) })
        await vm.selectSubtitleTrack(chinese)
        await vm.debugAwaitSubtitleFetch()

        #expect(resolveCount == resolvesAfterStart)                                   // no re-resolve
        #expect(fetchedURLs.first?.absoluteString.contains("/Subtitles/1/Stream.vtt") == true)
        #expect(vm.sidecarSubtitleInfo == SidecarSubtitleInfo(format: .vtt, byteCount: vtt.count))
        #expect(vm.subtitleRenderer != nil)
        #expect(vm.selectedSubtitleTrack?.id == .jellyfinStream(1))

        // Off → renderer + selection cleared, still no re-resolve.
        await vm.selectSubtitleTrack(nil)
        #expect(vm.subtitleRenderer == nil)
        #expect(vm.selectedSubtitleTrack == nil)
        #expect(resolveCount == resolvesAfterStart)
    }

    @Test("transcode: an .ass sidecar whose verbatim fetch fails falls back to the server's VTT conversion")
    func assSidecarFallsBackToVTTConversion() async throws {
        let reporting = StubPlaybackReporting()
        let engine = FakePlaybackEngine(id: .avKit, capabilities: .avKit)
        // The resolve hands out an ORIGINAL-format URL (authored styling preserved)…
        // No server default: the auto-activation on start() would otherwise run the
        // same fetch+fallback pair once before the explicit pick below.
        let assURL = URL(string: "https://jf.example.com/Videos/movie-1/ms-1/Subtitles/1/Stream.ass?api_key=abc")!
        let resolved = PlayerFixtures.resolvedMultiTrackTranscode(
            defaultSubtitleStreamIndex: nil,
            chineseSidecarURL: assURL
        )
        let vtt = Data("WEBVTT\n\n00:00:01.000 --> 00:00:03.000\nNi hao".utf8)

        nonisolated(unsafe) var fetchedURLs: [URL] = []
        let vm = makePlayerVM(
            reporting: reporting,
            resolve: { _, _, _, _ in resolved },
            engine: engine,
            // …but the server can't serve it verbatim (no writer for the format).
            subtitleFetch: { url in
                fetchedURLs.append(url)
                return url.path.hasSuffix(".ass") ? nil : vtt
            }
        )
        await vm.start(item: PlayerFixtures.movieDetail())

        let chinese = try #require(vm.availableSubtitleTracks.first { $0.id == .jellyfinStream(1) })
        await vm.selectSubtitleTrack(chinese)
        await vm.debugAwaitSubtitleFetch()

        // Exactly one retry, extension swapped, auth query preserved.
        #expect(fetchedURLs.map(\.lastPathComponent) == ["Stream.ass", "Stream.vtt"])
        #expect(fetchedURLs.last?.query?.contains("api_key") == true)
        #expect(vm.sidecarSubtitleInfo == SidecarSubtitleInfo(format: .vtt, byteCount: vtt.count))
        #expect(vm.subtitleRenderer != nil)
    }

    // MARK: - Style scope (who owns the look)

    private static func convertedAppearance(_ style: SubtitleStyle) -> SubtitleStyleOverride {
        style.convertedRendererOverride(
            surface: CGSize(width: 852, height: 393),
            canvas: CGRect(x: 0, y: 0, width: 852, height: 393)
        )
    }

    /// The whole rule, with no user switch left to consult: an SRT/VTT script is
    /// one WE synthesized, so the user's settings own every field of it; an ASS/SSA
    /// script is its creator's typesetting and is handed nothing, whatever the user
    /// picked. Its typefaces are still substituted, but that happens at load inside
    /// the renderer — never through an override.
    @Test("the user's style reaches converted tracks only, whatever they picked",
          arguments: [
            SubtitleStyle.standard,
            SubtitleStyle.standard.with {
                $0.fontScale = 2
                $0.fontDesign = .serif
                $0.background = .opaqueBox
                $0.foreground = .init(red: 1, green: 0.93, blue: 0.30)
                $0.verticalOffsetRatio = 0.18
            },
          ])
    func styleReachesConvertedTracksOnly(style: SubtitleStyle) async throws {
        let engine = FakePlaybackEngine(id: .avKit, capabilities: .avKit)
        let vm = makePlayerVM(engine: engine, resolved: PlayerFixtures.resolved())
        let converted = Self.convertedAppearance(style)

        vm.applySubtitleAppearance(converted: converted)

        #expect(vm.debugEffectiveStyleOverride(for: .srt) == converted)
        #expect(vm.debugEffectiveStyleOverride(for: .vtt) == converted)
        #expect(vm.debugEffectiveStyleOverride(for: .ass) == nil)
        #expect(vm.debugEffectiveStyleOverride(for: .ssa) == nil)
    }

    /// The same rule end to end, on a real fansub-shaped script: it fetches, it
    /// loads, the overlay pushes the user's style at it, and the renderer is still
    /// given nothing for it.
    @Test("an authored sidecar loads and is never given a style override")
    func authoredSidecarTakesNoOverride() async throws {
        let engine = FakePlaybackEngine(id: .avKit, capabilities: .avKit)
        let assURL = URL(string: "https://jf.example.com/Videos/movie-1/ms-1/Subtitles/1/Stream.ass?api_key=abc")!
        let resolved = PlayerFixtures.resolvedMultiTrackTranscode(
            defaultSubtitleStreamIndex: nil, chineseSidecarURL: assURL
        )
        let script = Data(Self.assScript.utf8)
        let vm = makePlayerVM(
            resolve: { _, _, _, _ in resolved },
            engine: engine,
            subtitleFetch: { _ in script }
        )
        await vm.start(item: PlayerFixtures.movieDetail())
        vm.applySubtitleAppearance(converted: Self.convertedAppearance(.standard))

        let track = try #require(vm.availableSubtitleTracks.first { $0.id == .jellyfinStream(1) })
        await vm.selectSubtitleTrack(track)
        await vm.debugAwaitSubtitleFetch()

        #expect(vm.sidecarSubtitleInfo?.format == .ass)
        #expect(vm.subtitleRenderer != nil)
        #expect(vm.debugEffectiveStyleOverride(for: .ass) == nil)
    }

    /// A minimal authored script: one dialogue line, a declared PlayRes, CRLF endings
    /// (what real fansubs ship, and what the header scan has to survive).
    private static let assScript = """
        [Script Info]\r
        ScriptType: v4.00+\r
        PlayResX: 1920\r
        PlayResY: 1080\r
        \r
        [V4+ Styles]\r
        Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding\r
        Style: Default,Arial,48,&H00FFFFFF,&H000000FF,&H00000000,&H80000000,0,0,0,0,100,100,0,0,1,2,1,2,40,40,36,1\r
        \r
        [Events]\r
        Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text\r
        Dialogue: 0,0:00:01.00,0:00:05.00,Default,,0,0,0,,Authored line\r
        """

    // MARK: - Embedded text subtitles render client-side on direct play

    @Test("direct play: an embedded TEXT pick installs the client renderer (the engine draws nothing)")
    func embeddedTextPickInstallsTheClientRenderer() async throws {
        let engine = FakePlaybackEngine(id: .vlcKit, capabilities: .vlcKit)
        let resolved = PlayerFixtures.resolvedDirectPlayEmbeddedSubs()
        let srt = Data("1\n00:00:01,000 --> 00:00:03,000\nEmbedded line\n".utf8)

        nonisolated(unsafe) var fetchedURLs: [URL] = []
        let vm = makePlayerVM(
            resolve: { _, _, _, _ in resolved },
            engine: engine,
            subtitleFetch: { url in fetchedURLs.append(url); return srt }
        )
        await vm.start(item: PlayerFixtures.movieDetail())
        // The engine's own inventory names the SAME embedded tracks; the server list
        // must win, so the text one carries a `.jellyfinStream` id and a sidecar URL.
        engine.push(.ready(duration: resolved.runtime!, tracks: TrackInventory(
            audio: [],
            subtitles: [SubtitleTrack(id: .vlc("vlc-s0"), displayName: "Track 1",
                                      languageCode: "en", isForced: false)]
        )))
        try await engine.settle()

        // The item has a PGS stream (index 3) with no sidecar, so the engine's renderer
        // stays ON for it — blinding it would cost the user that track. The text stream
        // is still ours: it is the `.jellyfinStream` row picked below.
        #expect(engine.loadedAssets.first?.engineSubtitlesDisabled == false)

        let text = try #require(vm.availableSubtitleTracks.first { $0.id == .jellyfinStream(2) })
        #expect(!text.isBurnedIn)
        await vm.selectSubtitleTrack(text)
        await vm.debugAwaitSubtitleFetch()

        #expect(fetchedURLs == [resolved.subtitleStreamURLs[2]])
        #expect(vm.subtitleRenderer != nil)
        #expect(vm.sidecarSubtitleInfo?.format == .srt)
        #expect(vm.selectedSubtitleTrack?.id == .jellyfinStream(2))
    }

    @Test("direct play: an IMAGE pick burns in server-side — no fetch, no client renderer")
    func embeddedImagePickDoesNotInstallARenderer() async throws {
        let engine = FakePlaybackEngine(id: .vlcKit, capabilities: .vlcKit)
        let resolved = PlayerFixtures.resolvedDirectPlayEmbeddedSubs()

        nonisolated(unsafe) var resolveCount = 0
        nonisolated(unsafe) var fetchCount = 0
        let vm = makePlayerVM(
            resolve: { _, _, _, _ in resolveCount += 1; return resolved },
            engine: engine,
            subtitleFetch: { _ in fetchCount += 1; return Data() }
        )
        await vm.start(item: PlayerFixtures.movieDetail())
        engine.push(.ready(duration: resolved.runtime!, tracks: .empty))
        try await engine.settle()
        let resolvesAfterStart = resolveCount

        let image = try #require(vm.availableSubtitleTracks.first { $0.id == .jellyfinStream(3) })
        #expect(image.isBurnedIn)
        await vm.selectSubtitleTrack(image)
        await vm.debugAwaitSubtitleFetch()

        #expect(fetchCount == 0)                     // image subs have no sidecar
        #expect(vm.subtitleRenderer == nil)
        #expect(resolveCount == resolvesAfterStart + 1)   // re-resolved for the burn-in
    }

    // MARK: - First-cue latency

    @Test("selecting a new sidecar drops the previous track's cues before the fetch, not after")
    func activatingASidecarClearsTheOutgoingCuesImmediately() async throws {
        let engine = FakePlaybackEngine(id: .vlcKit, capabilities: .vlcKit)
        let resolved = PlayerFixtures.resolvedDirectPlayEmbeddedSubs()
        let srt = Data("1\n00:00:01,000 --> 00:00:03,000\nEnglish line\n".utf8)
        // The SECOND track's fetch never lands. That window — a cold embedded stream
        // being extracted server-side — is exactly when the FIRST track's bitmaps
        // used to keep drawing under a menu that already said "French".
        let gate = AsyncStream<Void>.makeStream()
        let vm = makePlayerVM(
            resolve: { _, _, _, _ in resolved },
            engine: engine,
            subtitleFetch: { url in
                guard url.path.contains("/Subtitles/2/") else {
                    for await _ in gate.stream {}
                    return nil
                }
                return srt
            }
        )
        await vm.start(item: PlayerFixtures.movieDetail())
        engine.push(.ready(duration: resolved.runtime!, tracks: .empty))
        try await engine.settle()

        let english = try #require(vm.availableSubtitleTracks.first { $0.id == .jellyfinStream(2) })
        await vm.selectSubtitleTrack(english)
        await vm.debugAwaitSubtitleFetch()
        #expect(vm.subtitleRenderer != nil)

        let french = try #require(vm.availableSubtitleTracks.first { $0.id == .jellyfinStream(4) })
        await vm.selectSubtitleTrack(french)

        // Mid-fetch: the menu reads French, and the screen shows nothing rather than
        // the English cues it used to keep.
        #expect(vm.selectedSubtitleTrack?.id == .jellyfinStream(4))
        #expect(vm.subtitleRenderer == nil)
        #expect(vm.sidecarSubtitleInfo == nil)
        #expect(vm.loadingSubtitleTrackID == .jellyfinStream(4))

        gate.continuation.finish()
        await vm.debugAwaitSubtitleFetch()
    }

    @Test("re-selecting a track already fetched this session costs no second request")
    func sidecarBytesAreCachedForTheSession() async throws {
        let engine = FakePlaybackEngine(id: .avKit, capabilities: .avKit)
        let resolved = PlayerFixtures.resolvedMultiTrackTranscode(defaultSubtitleStreamIndex: nil)
        let vtt = Data("WEBVTT\n\n00:00:01.000 --> 00:00:03.000\nNi hao".utf8)

        nonisolated(unsafe) var fetchedURLs: [URL] = []
        let vm = makePlayerVM(
            resolve: { _, _, _, _ in resolved },
            engine: engine,
            subtitleFetch: { url in fetchedURLs.append(url); return vtt }
        )
        await vm.start(item: PlayerFixtures.movieDetail())

        let track = try #require(vm.availableSubtitleTracks.first { $0.id == .jellyfinStream(1) })
        for _ in 0..<3 {
            await vm.selectSubtitleTrack(track)
            await vm.debugAwaitSubtitleFetch()
            #expect(vm.subtitleRenderer != nil)
            await vm.selectSubtitleTrack(nil)
        }
        // One request for three selections: the expensive part of the first pick is
        // the server extracting an embedded stream through ffmpeg.
        #expect(fetchedURLs.count == 1)

        // A new session drops the cache — stream indices mean something else there.
        await vm.stop()
        #expect(vm.debugSubtitleURLs.isEmpty)
    }

    // MARK: - Source-agnostic subtitle URL map

    @Test("Jellyfin path populates subtitleURLs from resolved.subtitleStreamURLs (no behavior change)")
    func jellyfinPathPopulatesSubtitleURLMap() async throws {
        // resolved carries index 1 → a known VTT URL (from resolvedMultiTrackTranscode).
        // After start(), selecting that subtitle track must fetch exactly that URL.
        // This is the regression guard: if subtitleURLs isn't populated from resolved,
        // the lookup misses and no renderer is ever installed.
        let reporting = StubPlaybackReporting()
        let engine = FakePlaybackEngine(id: .avKit, capabilities: .avKit)
        let resolved = PlayerFixtures.resolvedMultiTrackTranscode()
        // The expected subtitle URL lives at resolved.subtitleStreamURLs[1].
        let expectedURL = try #require(resolved.subtitleStreamURLs[1])
        let vtt = Data("WEBVTT\n\n00:00:01.000 --> 00:00:02.000\nSubtitle text".utf8)

        nonisolated(unsafe) var fetchedURL: URL?
        let vm = makePlayerVM(
            reporting: reporting,
            resolve: { _, _, _, _ in resolved },
            engine: engine,
            subtitleFetch: { url in fetchedURL = url; return vtt }
        )
        await vm.start(item: PlayerFixtures.movieDetail())

        let chineseSub = try #require(vm.availableSubtitleTracks.first { $0.id == .jellyfinStream(1) })
        await vm.selectSubtitleTrack(chineseSub)
        await vm.debugAwaitSubtitleFetch()

        // The VM used the URL from resolved.subtitleStreamURLs — not a nil lookup.
        #expect(fetchedURL == expectedURL)
        #expect(vm.sidecarSubtitleInfo == SidecarSubtitleInfo(format: .vtt, byteCount: vtt.count))
    }

    @Test("setSubtitleDelay forwards to the engine (VLC's live retime; AVKit's is a protocol no-op)")
    func subtitleDelayForwardsToEngine() async throws {
        let reporting = StubPlaybackReporting()
        let engine = FakePlaybackEngine(id: .avKit, capabilities: .avKit)
        let vm = makePlayerVM(
            reporting: reporting,
            resolve: { _, _, _, _ in PlayerFixtures.resolved() },
            engine: engine
        )
        await vm.start(item: PlayerFixtures.movieDetail())

        await vm.setSubtitleDelay(ms: 250)
        #expect(engine.calls.contains("setSubtitleDelay(250)"))
    }

    @Test("isPlaying tracks engine play/pause so the button can resume from pause")
    func isPlayingTracksPauseState() async throws {
        let reporting = StubPlaybackReporting()
        let engine = FakePlaybackEngine(id: .avKit, capabilities: .avKit)
        let resolved = PlayerFixtures.resolved()
        let vm = makePlayerVM(reporting: reporting, engine: engine, resolved: resolved)
        await vm.start(item: PlayerFixtures.movieDetail())

        engine.push(.playing(10, duration: resolved.runtime!))
        try await engine.settle()
        #expect(vm.isPlaying == true)

        // The bug this guards: phase stays .playing while paused, so a phase-derived
        // button stayed "pause" forever. isPlaying must flip so resume is reachable.
        engine.push(.paused(10, duration: resolved.runtime!))
        try await engine.settle()
        #expect(vm.isPlaying == false)
        #expect(vm.phase == .playing)   // video surface stays up; only isPlaying flips
    }

    @Test("togglePlayPause flips isPlaying optimistically, before any engine beat")
    func togglePlayPauseIsOptimistic() async throws {
        let reporting = StubPlaybackReporting()
        let engine = FakePlaybackEngine(id: .avKit, capabilities: .avKit)
        let resolved = PlayerFixtures.resolved()
        let vm = makePlayerVM(reporting: reporting, engine: engine, resolved: resolved)
        await vm.start(item: PlayerFixtures.movieDetail())
        engine.push(.playing(10, duration: resolved.runtime!))
        try await engine.settle()
        #expect(vm.isPlaying == true)

        // FakePlaybackEngine's play()/pause() push NO state beat, so the only
        // thing that can flip isPlaying here is the optimistic write — which is
        // what keeps the glyph from lagging the tap by an engine round-trip.
        vm.togglePlayPause()
        #expect(vm.isPlaying == false)   // synchronous flip, before the command lands
        try await Task.sleep(for: .milliseconds(50))
        #expect(engine.calls.contains("pause"))

        vm.togglePlayPause()
        #expect(vm.isPlaying == true)
        try await Task.sleep(for: .milliseconds(50))
        #expect(engine.calls.contains("play"))
    }

    @Test("spammed togglePlayPause coalesces — last intent wins at the engine")
    func togglePlayPauseSpamCoalesces() async throws {
        let reporting = StubPlaybackReporting()
        let engine = FakePlaybackEngine(id: .avKit, capabilities: .avKit)
        let resolved = PlayerFixtures.resolved()
        let vm = makePlayerVM(reporting: reporting, engine: engine, resolved: resolved)
        await vm.start(item: PlayerFixtures.movieDetail())
        engine.push(.playing(10, duration: resolved.runtime!))
        try await engine.settle()
        #expect(vm.isPlaying == true)

        // Three rapid presses from playing: pause → play → pause. The glyph
        // follows parity instantly; the engine must end on the LAST intent —
        // earlier commands are cancelled before their await (cancel-previous),
        // so a stale play can never land after the final pause.
        vm.togglePlayPause()
        vm.togglePlayPause()
        vm.togglePlayPause()
        #expect(vm.isPlaying == false)   // parity of 3 toggles, instant

        try await Task.sleep(for: .milliseconds(100))
        let transport = engine.calls.filter { $0 == "play" || $0 == "pause" }
        #expect(transport.last == "pause")
    }

    /// The transport-glyph half of the exit wave. Every transport surface (the iPad/iPhone play-pause
    /// button, the tvOS paused overlay, both auto-hide guards) renders `desiredPlaying`, so
    /// this asserts on it directly. The scrub sandwich a drag performs (engine pause, commit,
    /// resume), plus every beat the engine emits inside it, must leave the shown state alone.
    /// This is what replaced the beat-pinning latch: nothing to pin when nothing reads the mirror.
    @Test("a scrub commit's transient beats never move what the transport surface shows")
    func scrubBeatsNeverMoveTheShownTransportState() async throws {
        let reporting = StubPlaybackReporting()
        let engine = FakePlaybackEngine(id: .avKit, capabilities: .avKit)
        let resolved = PlayerFixtures.resolved()
        let vm = makePlayerVM(reporting: reporting, engine: engine, resolved: resolved)
        await vm.start(item: PlayerFixtures.movieDetail())
        engine.push(.playing(10, duration: resolved.runtime!))
        try await engine.settle()
        #expect(vm.desiredPlaying == true)

        // The drag holds the still frame by pausing the ENGINE (never `setPlaying`), then commits.
        await vm.engine?.pause()
        await vm.commitScrubSeek(to: CMTime(seconds: 100, preferredTimescale: 600), resume: true)
        #expect(vm.desiredPlaying == true)

        // wmv/VLC settle window: the drag's own `.paused` beat lands after the commit already
        // replayed play(), and the confirming `.playing` beat is up to ~5s out. The mirror
        // believes the stale beat; the shown state must not.
        engine.push(.paused(100, duration: resolved.runtime!))
        try await engine.settle()
        #expect(vm.isPlaying == false)       // the mirror, mid-lag
        #expect(vm.desiredPlaying == true)   // what the overlay and the glyph render

        // And a GENUINE pause taken inside that same window shows at once, with no beat to
        // confirm it. That was the starvation the deleted `scrubResumePending` flag caused: it waited
        // on a mirror rising edge that wmv never delivered in time.
        vm.setPlaying(false)
        #expect(vm.desiredPlaying == false)
    }

    @Test("a remote (Now Playing) pause during a scrub commit shows immediately, not swallowed")
    func remoteCommandDuringScrubWins() async throws {
        let reporting = StubPlaybackReporting()
        let engine = FakePlaybackEngine(id: .avKit, capabilities: .avKit)
        let resolved = PlayerFixtures.resolved()
        let vm = makePlayerVM(reporting: reporting, engine: engine, resolved: resolved)
        await vm.start(item: PlayerFixtures.movieDetail())
        engine.push(.playing(10, duration: resolved.runtime!))
        try await engine.settle()

        // Scrub commit in flight (drag pause, seek issued, resume replayed).
        await vm.engine?.pause()
        await vm.commitScrubSeek(to: CMTime(seconds: 100, preferredTimescale: 600), resume: true)

        // The user hits Pause on the lock screen / headset, so Now Playing's onPause routes
        // through setPlaying(false). It must land on the press, and stay landed: AVKit emits
        // no further beat while paused, so nothing downstream would ever heal a swallowed one.
        vm.setPlaying(false)
        #expect(vm.desiredPlaying == false)
        try await Task.sleep(for: .milliseconds(50))
        #expect(engine.calls.contains("pause"))

        engine.push(.paused(100, duration: resolved.runtime!))
        try await engine.settle()
        #expect(vm.desiredPlaying == false)
    }

    /// The live bug this wave shipped with: `togglePlayPause` flipped the MIRROR, so a press
    /// inside the engine's lag window commanded the opposite of what the user asked for.
    @Test("togglePlayPause flips the user's intent, not the lagging engine mirror")
    func togglePlayPauseReadsIntentNotTheMirror() async throws {
        let engine = FakePlaybackEngine(id: .avKit, capabilities: .avKit)
        let resolved = PlayerFixtures.resolved()
        let vm = makePlayerVM(engine: engine, resolved: resolved)
        await vm.start(item: PlayerFixtures.movieDetail())
        engine.push(.playing(10, duration: resolved.runtime!))
        try await engine.settle()

        // Open the lag window the honest way: a scrub's engine-level pause, whose `.paused`
        // beat drives the mirror false while the user's intent stays "playing".
        await vm.engine?.pause()
        engine.push(.paused(10, duration: resolved.runtime!))
        try await engine.settle()
        #expect(vm.isPlaying == false)
        #expect(vm.desiredPlaying == true)

        // The press means "pause what I asked to be playing". Off the mirror it meant "play",
        // so the glyph flipped to pause and playback carried on.
        let before = engine.calls.count
        vm.togglePlayPause()
        #expect(vm.desiredPlaying == false)
        try await Task.sleep(for: .milliseconds(50))
        #expect(Array(engine.calls.dropFirst(before)) == ["pause"])
    }

    // MARK: - desiredPlaying: the user's transport intent, immune to the engine's beat lag

    @Test("engine beats drive isPlaying but never the intent: the mirror lags, the intent doesn't")
    func engineBeatsNeverWriteIntent() async throws {
        let engine = FakePlaybackEngine(id: .avKit, capabilities: .avKit)
        let resolved = PlayerFixtures.resolved()
        let vm = makePlayerVM(engine: engine, resolved: resolved)
        await vm.start(item: PlayerFixtures.movieDetail())
        #expect(vm.desiredPlaying == true)   // loadAndPlay's play() IS the intent to play

        // The whole transport beat vocabulary a live session emits between user commands.
        // Each drives the isPlaying MIRROR; none may touch the intent.
        for beat in [PlaybackState.paused(10, duration: resolved.runtime!),
                     .buffering(11, duration: resolved.runtime!),
                     .playing(12, duration: resolved.runtime!)] {
            engine.push(beat)
            try await engine.settle()
            #expect(vm.desiredPlaying == true)
        }
        #expect(vm.isPlaying == true)

        // Same in the other direction: an explicit pause sets the intent, and the beats that
        // follow it (including a stale `.playing` still in flight) leave it alone.
        vm.setPlaying(false)
        #expect(vm.desiredPlaying == false)
        engine.push(.playing(13, duration: resolved.runtime!))
        try await engine.settle()
        #expect(vm.isPlaying == true)        // mirror believes the stale beat
        #expect(vm.desiredPlaying == false)  // intent does not
    }

    @Test("scrub machinery pauses do NOT clear the intent: that's the whole point of surviving them")
    func scrubMachineryPauseKeepsIntent() async throws {
        let engine = FakePlaybackEngine(id: .avKit, capabilities: .avKit)
        let resolved = PlayerFixtures.resolved()
        let vm = makePlayerVM(engine: engine, resolved: resolved)
        await vm.start(item: PlayerFixtures.movieDetail())
        engine.push(.playing(10, duration: resolved.runtime!))
        try await engine.settle()

        // The iOS drag's entry pause and the tvOS reducer's `.pause` effect both go straight
        // to the engine: temporary holds on a still frame, not transport commands.
        await vm.engine?.pause()
        #expect(vm.desiredPlaying == true)
        engine.push(.paused(10, duration: resolved.runtime!))
        try await engine.settle()
        #expect(vm.desiredPlaying == true)
    }

    @Test("a seek inside the engine's beat lag still resumes: intent outlives the stale isPlaying mirror")
    func seekPreservingTransportResumesAgainstStalePausedBeat() async throws {
        let engine = FakePlaybackEngine(id: .avKit, capabilities: .avKit)
        let resolved = PlayerFixtures.resolved()
        let vm = makePlayerVM(engine: engine, resolved: resolved)
        await vm.start(item: PlayerFixtures.movieDetail())
        engine.push(.playing(10, duration: resolved.runtime!))
        try await engine.settle()

        // First scrub: pause on the still frame, commit, resume. The engine's own beats lag
        // that resume (VLC polls state every 500ms behind a seek-settlement gate; AVKit emits
        // nothing until the re-buffer ends), so the drag's stale `.paused` lands AFTER the
        // commit already replayed play(); isPlaying reads false while playback is resuming.
        await vm.engine?.pause()
        await vm.commitScrubSeek(to: CMTime(seconds: 100, preferredTimescale: 600), resume: true)
        engine.push(.paused(100, duration: resolved.runtime!))
        try await engine.settle()
        #expect(vm.isPlaying == false)       // the lag window
        #expect(vm.desiredPlaying == true)   // the user never asked for a pause

        // The SECOND seek captures intent, not the mirror: it must come back playing.
        // Reading the mirror here is the stuck-paused bug: resume: false, playback never resumes.
        let before = engine.calls.count
        await vm.seekPreservingTransport(to: CMTime(seconds: 200, preferredTimescale: 600))
        #expect(Array(engine.calls.dropFirst(before)) == ["seek(200.0)", "play"])
    }

    @Test("an explicit pause is honored across a stale .playing beat: a scrub there must NOT resume")
    func seekPreservingTransportHonorsExplicitPauseAgainstStalePlayingBeat() async throws {
        let engine = FakePlaybackEngine(id: .avKit, capabilities: .avKit)
        let resolved = PlayerFixtures.resolved()
        let vm = makePlayerVM(engine: engine, resolved: resolved)
        await vm.start(item: PlayerFixtures.movieDetail())
        engine.push(.playing(10, duration: resolved.runtime!))
        try await engine.settle()

        // User pauses; a `.playing` beat already in flight when the pause landed arrives after
        // it and re-flips the mirror. Lag in the opposite direction, same fix.
        vm.setPlaying(false)
        engine.push(.playing(10, duration: resolved.runtime!))
        try await engine.settle()
        #expect(vm.isPlaying == true)
        #expect(vm.desiredPlaying == false)

        let before = engine.calls.count
        await vm.seekPreservingTransport(to: CMTime(seconds: 200, preferredTimescale: 600))
        #expect(Array(engine.calls.dropFirst(before)) == ["seek(200.0)"])   // seek only, no resume
    }

    @Test("a re-anchor's force-resume never registers as user intent: a paused scrub stays paused start to finish")
    func pausedReanchorNeverLeaksResumeIntent() async throws {
        let engine = FakePlaybackEngine(id: .avKit, capabilities: .avKit)
        let resolved = PlayerFixtures.resolvedMultiTrackTranscode()
        let reencode = TranscodeDelivery(
            isVideoDirect: false, isAudioDirect: true,
            videoCodec: "h264", audioCodec: "ac3",
            transcodeReasons: ["VideoCodecNotSupported"]
        )
        let vm = makePlayerVM(
            resolve: { _, _, _, _ in resolved },
            engine: engine,
            fetchDelivery: { _ in reencode },
            deliveryProbeSchedule: [.milliseconds(10)]
        )
        await vm.start(item: PlayerFixtures.movieDetail())
        engine.push(.playing(10))
        try await Task.sleep(for: .milliseconds(80))

        // Sidecar overlay up so the out-of-buffer commit takes the re-anchor branch.
        let text = try #require(vm.availableSubtitleTracks.first { $0.id == .jellyfinStream(1) })
        await vm.selectSubtitleTrack(text)
        vm.setPlaying(false)
        #expect(vm.desiredPlaying == false)
        try await Task.sleep(for: .milliseconds(50))   // let setPlaying's own pause reach the engine first

        // `reloadTranscode`'s loadAndPlay force-resumes mechanically. If that resume were
        // recorded as intent, a second scrub landing during the (multi-second) reload would
        // capture a resume the paused user never asked for, so watch the flag for the whole
        // commit, not just its end state.
        engine.bufferedRange = 0...120
        let commit = Task { @MainActor in
            await vm.commitScrubSeek(to: CMTime(seconds: 3000, preferredTimescale: 600), resume: false)
        }
        nonisolated(unsafe) var leaked = false
        let watcher = Task { @MainActor in
            while !Task.isCancelled {
                if vm.desiredPlaying { leaked = true }
                await Task.yield()
            }
        }
        await commit.value
        watcher.cancel()

        #expect(leaked == false)
        #expect(vm.desiredPlaying == false)
        #expect(engine.calls.last == "pause")   // the reload's force-resume was undone
    }

    @Test("a natural end drops the intent: the next scrub can't resume a finished item")
    func endedBeatClearsIntent() async throws {
        let engine = FakePlaybackEngine(id: .avKit, capabilities: .avKit)
        let resolved = PlayerFixtures.resolved()
        let vm = makePlayerVM(engine: engine, resolved: resolved)
        await vm.start(item: PlayerFixtures.movieDetail())
        engine.push(.playing(10, duration: resolved.runtime!))
        try await engine.settle()
        #expect(vm.desiredPlaying == true)

        engine.push(.ended)
        try await engine.settle()
        #expect(vm.desiredPlaying == false)
    }

    // MARK: - Exit: audio ends at the fence, and nothing after it may restart playback

    @Test("beginExit ENDS audio rather than silencing it: silence leaves VLC's queued samples playing")
    func beginExitEndsAudio() async throws {
        let engine = FakePlaybackEngine(id: .vlcKit, capabilities: .vlcKit)
        let resolved = PlayerFixtures.resolved()
        let vm = makePlayerVM(engine: engine, resolved: resolved)
        await vm.start(item: PlayerFixtures.movieDetail())

        let before = engine.calls.count
        vm.beginExit()
        await waitUntil { engine.calls.count > before }
        #expect(Array(engine.calls.dropFirst(before)) == ["endAudio"])
    }

    /// The close button fences, then the presenter's `dismiss()` fences again through its
    /// exit handler. A session ends once.
    @Test("beginExit is idempotent: the presenter's second fence is inert")
    func beginExitIsIdempotent() async throws {
        let engine = FakePlaybackEngine(id: .vlcKit, capabilities: .vlcKit)
        let vm = makePlayerVM(engine: engine, resolved: PlayerFixtures.resolved())
        await vm.start(item: PlayerFixtures.movieDetail())

        let before = engine.calls.count
        vm.beginExit()
        vm.beginExit()
        await waitUntil { engine.calls.count > before }
        await Task.yield()
        #expect(Array(engine.calls.dropFirst(before)) == ["endAudio"])
    }

    /// THE hole this closes: every scrub surface coalesces its commit (~400ms), so a drag
    /// released just before the close button fires INTO the dismiss animation. Its resume
    /// branch would `engine.play()`, unmuting and restarting the audio the exit just ended,
    /// for the rest of the slide-out. Both resume states, because the `else` branch commands
    /// the engine too (a re-anchor's force-resume gets re-paused).
    @Test("a scrub commit landing after the exit fence never touches the engine",
          arguments: [true, false])
    func commitScrubSeekIsFencedByExit(resume: Bool) async throws {
        let engine = FakePlaybackEngine(id: .vlcKit, capabilities: .vlcKit)
        let resolved = PlayerFixtures.resolved()
        let vm = makePlayerVM(engine: engine, resolved: resolved)
        await vm.start(item: PlayerFixtures.movieDetail())
        engine.push(.playing(10, duration: resolved.runtime!))
        try await engine.settle()

        vm.beginExit()
        await waitUntil { engine.calls.last == "endAudio" }

        let before = engine.calls.count
        await vm.commitScrubSeek(to: CMTime(seconds: 200, preferredTimescale: 600), resume: resume)
        #expect(Array(engine.calls.dropFirst(before)).isEmpty)
    }

    /// The interleave the entry fence alone can't catch: the commit is already PAST it and
    /// suspended inside `await seek(to:)` when the close button lands. `beginExit()` is
    /// synchronous MainActor work, so it slips into exactly that window; the seek then returns
    /// `false` because ITS fence refused it, which is indistinguishable from an ordinary
    /// in-stream seek, and the resume branch calls `engine.play()`. On AVKit nothing downstream
    /// catches that (no engine latch), so audio comes back for the rest of the slide-out.
    @Test("a commit suspended in its seek re-checks the fence before resuming")
    func commitScrubSeekRechecksTheFenceAfterItsSeek() async throws {
        let engine = FakePlaybackEngine(id: .avKit, capabilities: .avKit)
        let resolved = PlayerFixtures.resolved()
        let vm = makePlayerVM(engine: engine, resolved: resolved)
        await vm.start(item: PlayerFixtures.movieDetail())
        engine.push(.playing(10, duration: resolved.runtime!))
        try await engine.settle()

        // Park the commit inside its engine seek so the fence lands mid-await, deterministically.
        engine.holdSeeks()
        let before = engine.calls.count
        let commit = Task { @MainActor in
            await vm.commitScrubSeek(to: CMTime(seconds: 200, preferredTimescale: 600), resume: true)
        }
        await waitUntil { engine.hasParkedSeek }

        vm.beginExit()
        engine.releaseSeeks()
        await commit.value

        #expect(!Array(engine.calls.dropFirst(before)).contains("play"))
    }

    /// Same fence one level down, for the surfaces that seek without a transport replay
    /// (chapter list, remote-command seek): a seek into a stopped session would re-buffer,
    /// or on a transcode re-anchor a whole new encode, behind the dismissed player.
    @Test("a seek landing after the exit fence never touches the engine")
    func seekIsFencedByExit() async throws {
        let engine = FakePlaybackEngine(id: .vlcKit, capabilities: .vlcKit)
        let resolved = PlayerFixtures.resolved()
        let vm = makePlayerVM(engine: engine, resolved: resolved)
        await vm.start(item: PlayerFixtures.movieDetail())
        engine.push(.playing(10, duration: resolved.runtime!))
        try await engine.settle()

        vm.beginExit()
        await waitUntil { engine.calls.last == "endAudio" }

        let before = engine.calls.count
        let reanchored = await vm.seek(to: CMTime(seconds: 200, preferredTimescale: 600))
        #expect(reanchored == false)
        #expect(Array(engine.calls.dropFirst(before)).isEmpty)
    }

    /// `seekPreservingTransport` is the one every non-scrub surface calls, and it reads the
    /// live intent, which is still `true` for a player exiting mid-playback. It must inherit
    /// the fence, not route around it.
    @Test("seekPreservingTransport inherits the exit fence")
    func seekPreservingTransportIsFencedByExit() async throws {
        let engine = FakePlaybackEngine(id: .vlcKit, capabilities: .vlcKit)
        let resolved = PlayerFixtures.resolved()
        let vm = makePlayerVM(engine: engine, resolved: resolved)
        await vm.start(item: PlayerFixtures.movieDetail())
        engine.push(.playing(10, duration: resolved.runtime!))
        try await engine.settle()
        #expect(vm.desiredPlaying == true)

        vm.beginExit()
        await waitUntil { engine.calls.last == "endAudio" }

        let before = engine.calls.count
        await vm.seekPreservingTransport(to: CMTime(seconds: 200, preferredTimescale: 600))
        #expect(Array(engine.calls.dropFirst(before)).isEmpty)
    }

    /// The Now Playing / lock-screen commands stay registered until `stop()` clears them, so a
    /// play tapped there can land inside the dismiss animation. On AVKit nothing downstream
    /// catches it (the engine has no exit latch of its own) and playback comes back audible
    /// under a player already sliding away.
    @Test("a transport command landing after the exit fence never reaches the engine",
          arguments: [true, false])
    func setPlayingIsFencedByExit(playing: Bool) async throws {
        let engine = FakePlaybackEngine(id: .avKit, capabilities: .avKit)
        let resolved = PlayerFixtures.resolved()
        let vm = makePlayerVM(engine: engine, resolved: resolved)
        await vm.start(item: PlayerFixtures.movieDetail())
        engine.push(.playing(10, duration: resolved.runtime!))
        try await engine.settle()

        vm.beginExit()
        await waitUntil { engine.calls.last == "endAudio" }

        let before = engine.calls.count
        vm.setPlaying(playing)
        // The fence returns before any suspension, so nothing was even armed; the yields
        // give a transport task that DID get armed every chance to reach the engine.
        await Task.yield()
        await Task.yield()
        #expect(Array(engine.calls.dropFirst(before)).isEmpty)
        #expect(vm.desiredPlaying == true)   // the fence blocks the intent write too
    }

    /// The other half of the race: the command arrives just BEFORE the fence, so its engine
    /// hop is already armed when the close button lands. `beginExit()` cancels it, and the
    /// task's own cancellation check sits ahead of the engine call. Ordering is deterministic
    /// here: both tasks are enqueued on the MainActor, transport first, so "endAudio" landing
    /// proves the transport task already ran and chose to do nothing.
    @Test("a transport command armed just before the fence is cancelled by it")
    func armedTransportTaskIsCancelledByExit() async throws {
        let engine = FakePlaybackEngine(id: .avKit, capabilities: .avKit)
        let resolved = PlayerFixtures.resolved()
        let vm = makePlayerVM(engine: engine, resolved: resolved)
        await vm.start(item: PlayerFixtures.movieDetail())
        engine.push(.playing(10, duration: resolved.runtime!))
        try await engine.settle()
        vm.setPlaying(false)
        await waitUntil { engine.calls.last == "pause" }

        let before = engine.calls.count
        vm.setPlaying(true)      // armed, not yet hopped
        vm.beginExit()           // same synchronous run: cancels it before it can
        await waitUntil { engine.calls.last == "endAudio" }
        #expect(Array(engine.calls.dropFirst(before)) == ["endAudio"])
    }

    // MARK: - The exit freeze is terminal: no beat may uncover the closing vout

    /// Beats keep coming after the fence. AVKit's default `endAudio()` funnels to `pause()`,
    /// which yields a `.paused` beat synchronously; VLC's poll swallows the cancellation
    /// `endAudio()` issues inside a `try?` sleep and runs one more tick. Either one used to
    /// crossfade the exit still away mid-slide-out, onto a vout already closing under it: a
    /// visible cut to black.
    @Test("beats arriving after the exit fence never release the held frame",
          arguments: [true, false])
    func exitFreezeSurvivesLateBeats(playing: Bool) async throws {
        let engine = FakePlaybackEngine(id: .vlcKit, capabilities: .vlcKit)
        let resolved = PlayerFixtures.resolved()
        let vm = makePlayerVM(engine: engine, resolved: resolved)
        nonisolated(unsafe) var freezeCalls = 0
        nonisolated(unsafe) var unfreezeCalls = 0
        vm.freezeSurfaceAction = { freezeCalls += 1 }
        vm.unfreezeSurfaceAction = { unfreezeCalls += 1 }

        await vm.start(item: PlayerFixtures.movieDetail())
        engine.push(.playing(10, duration: resolved.runtime!))
        try await engine.settle()
        #expect(freezeCalls == 0)

        vm.beginExit()
        #expect(freezeCalls == 1)

        let late: PlaybackState = playing
            ? .playing(11, duration: resolved.runtime!)
            : .paused(11, duration: resolved.runtime!)
        engine.push(late)
        try await engine.settle()
        #expect(unfreezeCalls == 0)

        // A terminal beat is fenced too: the stopping input can surface a failure under the
        // outgoing card, and the error scrim is not what the user should see sliding away.
        engine.push(.failed(.assetNotPlayable))
        try await engine.settle()
        #expect(unfreezeCalls == 0)

        // And the teardown that follows leaves the still up for the whole dismissal.
        await vm.stop()
        #expect(unfreezeCalls == 0)
    }

    /// The flip side of `stop()` no longer releasing the frame: a retry replays onto the SAME
    /// host view, and a still left pinned there would sit over the replayed video forever
    /// (the beat-side release guards on the flag and would no-op). `resetForReplay` releases
    /// it right after it disarms the fence.
    @Test("a retry releases the frame the exit fence held through stop()")
    func retryReleasesHeldFrame() async throws {
        let engine = FakePlaybackEngine(id: .avKit, capabilities: .avKit)
        let resolved = PlayerFixtures.resolvedMultiTrackTranscode()
        let vm = makePlayerVM(
            resolve: { _, _, _, _ in resolved },
            engine: engine,
            subtitleFetch: { _ in Data() }
        )
        nonisolated(unsafe) var freezeCalls = 0
        nonisolated(unsafe) var unfreezeCalls = 0
        vm.freezeSurfaceAction = { freezeCalls += 1 }
        vm.unfreezeSurfaceAction = { unfreezeCalls += 1 }

        await vm.start(item: PlayerFixtures.movieDetail())
        engine.push(.playing(10))
        try await engine.settle()

        // Out-of-buffer commit with a sidecar up → re-anchor reload → the frame is held, and
        // no beat follows, so it is still held when the user reaches for retry.
        engine.bufferedRange = 0...120
        await vm.commitScrubSeek(to: CMTime(seconds: 3000, preferredTimescale: 600), resume: true)
        #expect(freezeCalls == 1)
        #expect(unfreezeCalls == 0)

        await vm.retry()
        #expect(unfreezeCalls == 1)
    }

    @Test("buffered beat → bufferedFraction; nil beat (VLC) hides the layer; stop() clears it")
    func bufferedFractionTracksBeats() async throws {
        let reporting = StubPlaybackReporting()
        let engine = FakePlaybackEngine(id: .avKit, capabilities: .avKit)
        let resolved = PlayerFixtures.resolved()
        let vm = makePlayerVM(reporting: reporting, engine: engine, resolved: resolved)
        await vm.start(item: PlayerFixtures.movieDetail())

        // runtime fixture is the duration; buffer extends to its midpoint.
        let duration = resolved.runtime!
        let half = CMTime(seconds: CMTimeGetSeconds(duration) / 2, preferredTimescale: 600)
        engine.push(.playing(10, duration: duration, buffered: half))
        try await engine.settle()
        let fraction = try #require(vm.bufferedFraction)
        #expect(abs(fraction - 0.5) < 0.001)

        // A nil buffered beat (VLC path) must hide the layer, not freeze the last value.
        engine.push(.paused(10, duration: duration))
        try await engine.settle()
        #expect(vm.bufferedFraction == nil)

        await vm.stop()
        #expect(vm.bufferedFraction == nil)
    }

    @Test("mid-stream stall: .buffering beats raise isStalled after the debounce; playing clears it edge-on")
    func stallDebounceLifecycle() async throws {
        let reporting = StubPlaybackReporting()
        let engine = FakePlaybackEngine(id: .avKit, capabilities: .avKit)
        let resolved = PlayerFixtures.resolved()
        let vm = makePlayerVM(reporting: reporting, engine: engine, resolved: resolved)
        await vm.start(item: PlayerFixtures.movieDetail())

        engine.push(.playing(10, duration: resolved.runtime!))
        try await engine.settle()

        // A short blip (healthy in-buffer seek) never shows the scrim.
        engine.push(.buffering(10, duration: resolved.runtime!))
        try await engine.settle()
        #expect(vm.isStalled == false)
        engine.push(.playing(11, duration: resolved.runtime!))
        try await Task.sleep(for: .milliseconds(500))
        #expect(vm.isStalled == false)   // debounce was cancelled, not just delayed

        // A real stall crosses the debounce: scrim shows, phase + intent untouched.
        engine.push(.buffering(11, duration: resolved.runtime!))
        try await Task.sleep(for: .milliseconds(600))
        #expect(vm.isStalled == true)
        #expect(vm.showsStallScrim == true)
        // The scrim reads the mid-stream caption, NOT the cold-start "Loading video"
        // one — same surface, different flavor.
        #expect(vm.loaderTitle == PlayerViewModel.LoaderCaption.buffering)
        #expect(vm.phase == .playing)
        #expect(vm.isPlaying == true)

        // Recovery clears it immediately.
        engine.push(.playing(12, duration: resolved.runtime!))
        try await engine.settle()
        #expect(vm.isStalled == false)
        #expect(vm.showsStallScrim == false)

        // Paused-seek shape (drag-scrub commits pause → seek → play): the engine surfaces the
        // out-of-buffer fetch as a `.projected` .buffering at the target, which stalls
        // immediately (no debounce — the label says a seek is unresolved, so the fetch is real
        // by construction); the completion's .paused beat clears it, no .playing required.
        engine.push(.buffering(300, duration: resolved.runtime!, provenance: .projected))
        try await engine.settle()
        #expect(vm.isStalled == true)
        engine.push(.paused(300, duration: resolved.runtime!))
        try await engine.settle()
        #expect(vm.isStalled == false)
        #expect(vm.isPlaying == false)
    }

    @Test("transcode track switch closes the outgoing session before opening the next")
    func transcodeSwitchClosesOldSession() async throws {
        let reporting = StubPlaybackReporting()
        let engine = FakePlaybackEngine(id: .avKit, capabilities: .avKit)
        let resolved = PlayerFixtures.resolvedMultiTrackTranscode()
        let vm = makePlayerVM(
            reporting: reporting,
            resolve: { _, _, _, _ in resolved },
            engine: engine
        )
        await vm.start(item: PlayerFixtures.movieDetail())
        engine.push(.playing(100))
        try await engine.settle()

        let track = try #require(vm.availableAudioTracks.first { $0.id == .jellyfinStream(4) })
        await vm.selectAudioTrack(track)

        // The outgoing transcode session must get a stopped beat so the server
        // doesn't leak it — switching tracks re-resolves a fresh play session.
        let events = await reporting.events
        let stoppedCount = events.filter { if case .stopped = $0 { return true } else { return false } }.count
        #expect(stoppedCount == 1)
        // …and its ENCODING must be killed explicitly (DELETE
        // /Videos/ActiveEncodings): with throttling off an abandoned job keeps
        // transcoding flat-out and starves the replacement job's segments past
        // AVPlayer's 3s timeout — the post-switch -12889 buffering livelock.
        let killed = await reporting.stoppedEncodings
        #expect(killed == [resolved.playSessionID])
    }

    @Test("transcode session pings its keepalive on the interval; stop() ends it; direct play never pings")
    func transcodeKeepalive() async throws {
        let reporting = StubPlaybackReporting()
        let engine = FakePlaybackEngine(id: .avKit, capabilities: .avKit)
        let resolved = PlayerFixtures.resolvedMultiTrackTranscode()
        let vm = makePlayerVM(
            reporting: reporting,
            resolve: { _, _, _, _ in resolved },
            engine: engine,
            keepaliveInterval: .milliseconds(20)
        )
        await vm.start(item: PlayerFixtures.movieDetail())
        try await Task.sleep(for: .milliseconds(120))
        // Pings flow on the interval, addressed to the live session — they keep
        // the server's 60s idle kill from reaping the job (and its segments)
        // during a long pause, when segment requests and progress beats both stop.
        let pings = await reporting.pings
        #expect(!pings.isEmpty)
        #expect(pings.allSatisfy { $0 == resolved.playSessionID })

        await vm.stop()
        let countAtStop = await reporting.pings.count
        try await Task.sleep(for: .milliseconds(100))
        #expect(await reporting.pings.count == countAtStop)

        // Direct play has no transcode job — no keepalive is armed.
        let directReporting = StubPlaybackReporting()
        let directVM = makePlayerVM(
            reporting: directReporting,
            resolve: { _, _, _, _ in PlayerFixtures.resolved() },
            engineFactory: { _, _ in FakePlaybackEngine(id: .avKit, capabilities: .avKit) },
            keepaliveInterval: .milliseconds(20)
        )
        await directVM.start(item: PlayerFixtures.movieDetail())
        try await Task.sleep(for: .milliseconds(100))
        #expect(await directReporting.pings.isEmpty)
        await directVM.stop()
    }

    @Test("a failed load kills the just-resolved encoding and stops its keepalive")
    func loadFailureTearsDownSessionLifecycle() async throws {
        let reporting = StubPlaybackReporting()
        let engine = FakePlaybackEngine(id: .avKit, capabilities: .avKit)
        engine.loadError = AppError.playback(.unsupportedFormat)
        let resolved = PlayerFixtures.resolvedMultiTrackTranscode()
        let vm = makePlayerVM(
            reporting: reporting,
            resolve: { _, _, _, _ in resolved },
            engine: engine,
            keepaliveInterval: .milliseconds(20)
        )
        await vm.start(item: PlayerFixtures.movieDetail())
        // The keepalive arms at resolve time (the job exists from then on), so a
        // load failure must tear BOTH down: without the explicit kill + ping
        // cancel, the pings keep an orphaned ffmpeg job transcoding flat-out for
        // as long as the user sits on the failure overlay.
        #expect(await reporting.stoppedEncodings == [resolved.playSessionID])
        let pingsAtFailure = await reporting.pings.count
        try await Task.sleep(for: .milliseconds(100))
        #expect(await reporting.pings.count == pingsAtFailure)
    }

    @Test("selectAudioTrack forwards to the engine and updates selectedAudioTrack")
    func audioTrackSelectionForwardsToEngine() async throws {
        let reporting = StubPlaybackReporting()
        let engine = FakePlaybackEngine(id: .avKit, capabilities: .avKit)
        let vm = makePlayerVM(reporting: reporting, engine: engine, resolved: PlayerFixtures.resolved())
        await vm.start(item: PlayerFixtures.movieDetail())

        let track = AudioTrack(id: .avKitOption(1), displayName: "English", languageCode: "en")
        engine.push(.ready(duration: CMTime(seconds: 7200, preferredTimescale: 600), tracks: TrackInventory(audio: [track], subtitles: [])))
        try await engine.settle()

        await vm.selectAudioTrack(track)
        #expect(vm.selectedAudioTrack?.id == .avKitOption(1))
        #expect(engine.selectedAudioTrackID == .avKitOption(1))
    }

    /// Nothing we ship decodes TrueHD, so the engine marks those tracks and the menu greys
    /// them — but the menu isn't the only caller (remote commands, the playback lab), so the
    /// view model is where the rule has to hold. Picking one must leave BOTH the engine and
    /// the checkmark on the track that is actually playing, or the user gets silence plus a
    /// menu that claims otherwise.
    @Test("selectAudioTrack ignores a track the engine cannot decode")
    func unsupportedAudioTrackIsNotSelectable() async throws {
        let engine = FakePlaybackEngine(id: .vlcKit, capabilities: .vlcKit)
        let vm = makePlayerVM(engine: engine, resolved: PlayerFixtures.resolvedVP9WebM())
        await vm.start(item: PlayerFixtures.movieDetail())

        let compatibility = AudioTrack(id: .vlc("1"), displayName: "English", languageCode: "en")
        let trueHD = AudioTrack(id: .vlc("2"), displayName: "English", languageCode: "en",
                                detailLabel: "TrueHD · 7.1", isUnsupported: true)
        engine.push(.ready(
            duration: CMTime(seconds: 3600, preferredTimescale: 600),
            tracks: TrackInventory(audio: [compatibility, trueHD], subtitles: [])
        ))
        try await engine.settle()

        await vm.selectAudioTrack(compatibility)
        await vm.selectAudioTrack(trueHD)

        #expect(vm.selectedAudioTrack?.id == .vlc("1"))
        #expect(engine.selectedAudioTrackID == .vlc("1"))
    }

    @Test("selectSubtitleTrack nil deselects and forwards nil to engine")
    func subtitleTrackDeselect() async throws {
        let reporting = StubPlaybackReporting()
        let engine = FakePlaybackEngine(id: .avKit, capabilities: .avKit)
        let vm = makePlayerVM(reporting: reporting, engine: engine, resolved: PlayerFixtures.resolved())
        await vm.start(item: PlayerFixtures.movieDetail())

        let sub = SubtitleTrack(id: .avKitOption(1), displayName: "English", languageCode: "en", isForced: false)
        engine.push(.ready(duration: CMTime(seconds: 7200, preferredTimescale: 600), tracks: TrackInventory(audio: [], subtitles: [sub])))
        try await engine.settle()

        await vm.selectSubtitleTrack(sub)
        #expect(vm.selectedSubtitleTrack?.id == .avKitOption(1))

        await vm.selectSubtitleTrack(nil)
        #expect(vm.selectedSubtitleTrack == nil)
        #expect(engine.selectedSubtitleTrackID == nil)
    }

    @Test(".vlcKit engine tracks populate on .ready state")
    func vlcEngineTrackStatePopulates() async throws {
        let vlcEngine = FakePlaybackEngine(id: .vlcKit, capabilities: .vlcKit)
        let vm = makePlayerVM(engine: vlcEngine, resolved: PlayerFixtures.resolvedVP9WebM())
        await vm.start(item: PlayerFixtures.movieDetail())

        let inventory = TrackInventory(
            audio: [AudioTrack(id: .vlc("vlc-a1"), displayName: "Deutsch", languageCode: "de")],
            subtitles: [SubtitleTrack(id: .vlc("vlc-s1"), displayName: "ASS Sub", languageCode: "en", isForced: false)]
        )
        vlcEngine.push(.ready(duration: CMTime(seconds: 3600, preferredTimescale: 600), tracks: inventory))
        try await vlcEngine.settle()

        #expect(vm.availableAudioTracks.count == 1)
        #expect(vm.availableAudioTracks[0].id == .vlc("vlc-a1"))
        #expect(vm.availableSubtitleTracks.count == 1)
    }

    @Test("isPiPAvailable / isVideoAirPlayAvailable mirror the engine's capabilities")
    func routeAvailabilityMirrorsCapabilities() async {
        let engine = FakePlaybackEngine(id: .avKit, capabilities: .avKit)
        let vm = makePlayerVM(engine: engine, resolved: PlayerFixtures.resolved())
        await vm.start(item: PlayerFixtures.movieDetail())
        #expect(vm.isPiPAvailable == engine.capabilities.supportsPiP)
        #expect(vm.isVideoAirPlayAvailable == engine.capabilities.supportsVideoAirPlay)
        // …and the fake's caps are the AVKit ones, so both flags read true here.
        #expect(vm.isPiPAvailable == true)
        #expect(vm.isVideoAirPlayAvailable == true)
    }

    @Test("natural end followed by dismissal reports stopped exactly once")
    func endThenDismissReportsStoppedOnce() async throws {
        let reporting = StubPlaybackReporting()
        let engine = FakePlaybackEngine(id: .avKit, capabilities: .avKit)
        let resolved = PlayerFixtures.resolved()

        let vm = makePlayerVM(reporting: reporting, engine: engine, resolved: resolved)
        await vm.start(item: PlayerFixtures.movieDetail())
        engine.push(.playing(40, duration: resolved.runtime!))
        engine.push(.ended)
        try await engine.settle()

        // PlayerView.onDisappear always calls stop(); after a natural .ended that
        // already reported stopped, stop() must NOT emit a second stopped beat.
        await vm.stop()

        let events = await reporting.events
        let stoppedCount = events.filter { if case .stopped = $0 { return true } else { return false } }.count
        #expect(stoppedCount == 1)
    }

    @Test("transcode switch whose re-resolve fails reports stop exactly once — no double, no orphan")
    func transcodeSwitchResolveFailureReportsStoppedOnce() async throws {
        let reporting = StubPlaybackReporting()
        let engine = FakePlaybackEngine(id: .avKit, capabilities: .avKit)
        let resolved = PlayerFixtures.resolvedMultiTrackTranscode()

        nonisolated(unsafe) var callCount = 0
        let vm = makePlayerVM(
            reporting: reporting,
            resolve: { _, _, _, _ in
                callCount += 1
                if callCount >= 2 { throw AppError.playback(.resourceUnavailable) }  // the switch re-resolve fails
                return resolved
            },
            engine: engine
        )
        await vm.start(item: PlayerFixtures.movieDetail())
        engine.push(.playing(100))
        try await engine.settle()

        // Switch audio → the re-resolve throws → silent fallback (playback resumes).
        let track = try #require(vm.availableAudioTracks.first { $0.id == .jellyfinStream(4) })
        await vm.selectAudioTrack(track)

        // Dismiss → stop(). The outgoing session was already closed by the switch; the
        // failed session was never started, so stop() must NOT fire a second stop.
        await vm.stop()

        let stoppedCount = (await reporting.events).filter { if case .stopped = $0 { return true } else { return false } }.count
        #expect(stoppedCount == 1)
    }

    @Test("failed transcode switch falls back silently: playback resumes on the previous track, the failure is surfaced for retry")
    func transcodeSwitchFailureFallsBackSilently() async throws {
        let reporting = StubPlaybackReporting()
        let engine = FakePlaybackEngine(id: .avKit, capabilities: .avKit)
        let resolved = PlayerFixtures.resolvedMultiTrackTranscode()

        nonisolated(unsafe) var callCount = 0
        let vm = makePlayerVM(
            reporting: reporting,
            resolve: { _, _, _, _ in
                callCount += 1
                if callCount == 2 { throw AppError.playback(.resourceUnavailable) }  // the switch re-resolve fails
                return resolved
            },
            engine: engine
        )
        await vm.start(item: PlayerFixtures.movieDetail())
        engine.push(.playing(100))
        try await engine.settle()

        let track = try #require(vm.availableAudioTracks.first { $0.id == .jellyfinStream(4) })
        await vm.selectAudioTrack(track)

        // Failures are loud, fallbacks are silent: the old stream (still mounted —
        // resolve threw before the reload) resumes instead of phase going .failed.
        #expect(vm.phase == .playing)
        #expect(!engine.calls.contains("teardown"))
        #expect(engine.calls.filter { $0 == "play" }.count == 2)        // initial play + fallback resume
        // The scrim's state: the requested track is the retry target, the menu
        // checkmark is back on the track that's actually playing.
        #expect(vm.trackSwitchFailure?.requested.id == .jellyfinStream(4))
        #expect(vm.trackSwitchFailure?.fallback?.id == .jellyfinStream(3))
        #expect(vm.selectedAudioTrack?.id == .jellyfinStream(3))

        // "Keep current track" clears the scrim without touching playback.
        vm.dismissTrackSwitchFailure()
        #expect(vm.trackSwitchFailure == nil)
        #expect(vm.phase == .playing)
    }

    @Test("a failed switch racing an exit abandons instead of resuming audio under the dismissed player")
    func transcodeSwitchFailureDuringExitAbandons() async throws {
        let reporting = StubPlaybackReporting()
        let engine = FakePlaybackEngine(id: .avKit, capabilities: .avKit)
        let resolved = PlayerFixtures.resolvedMultiTrackTranscode()

        // The switch's re-resolve is where exit can race in: beginExit() lands while
        // resolve is suspended, then resolve throws a REAL error — which skips every
        // checkStillActive (those only catch CancellationError paths).
        nonisolated(unsafe) var callCount = 0
        nonisolated(unsafe) var triggerExit: (@MainActor () -> Void)? = nil
        let vm = makePlayerVM(
            reporting: reporting,
            resolve: { _, _, _, _ in
                callCount += 1
                if callCount == 2 {
                    await MainActor.run { triggerExit?() }
                    throw AppError.playback(.resourceUnavailable)
                }
                return resolved
            },
            engine: engine
        )
        triggerExit = { vm.beginExit() }
        await vm.start(item: PlayerFixtures.movieDetail())
        engine.push(.playing(100))
        try await engine.settle()

        let track = try #require(vm.availableAudioTracks.first { $0.id == .jellyfinStream(4) })
        await vm.selectAudioTrack(track)

        // No fallback resume (the initial play stands alone), no scrim, selection restored.
        #expect(engine.calls.filter { $0 == "play" }.count == 1)
        #expect(vm.trackSwitchFailure == nil)
        #expect(vm.selectedAudioTrack?.id == .jellyfinStream(3))

        // The exit's own stop() still tears down cleanly, with no extra stop report
        // (the switch already closed the outgoing session; the new one never started).
        await vm.stop()
        #expect(engine.calls.contains("teardown"))
        let stoppedCount = (await reporting.events).filter { if case .stopped = $0 { return true } else { return false } }.count
        #expect(stoppedCount == 1)
    }

    @Test("retryFailedTrackSwitch re-attempts the requested track and clears the failure on success")
    func retryFailedTrackSwitchReattempts() async throws {
        let reporting = StubPlaybackReporting()
        let engine = FakePlaybackEngine(id: .avKit, capabilities: .avKit)
        let resolved = PlayerFixtures.resolvedMultiTrackTranscode()

        nonisolated(unsafe) var resolveCalls: [Int?] = []
        let vm = makePlayerVM(
            reporting: reporting,
            resolve: { _, _, _, selection in
                resolveCalls.append(selection?.audioStreamIndex)
                if resolveCalls.count == 2 { throw AppError.playback(.resourceUnavailable) }  // first switch fails
                return resolved                                                               // retry succeeds
            },
            engine: engine
        )
        await vm.start(item: PlayerFixtures.movieDetail())
        engine.push(.playing(100))
        try await engine.settle()

        let track = try #require(vm.availableAudioTracks.first { $0.id == .jellyfinStream(4) })
        await vm.selectAudioTrack(track)
        #expect(vm.trackSwitchFailure != nil)

        await vm.retryFailedTrackSwitch()

        #expect(vm.trackSwitchFailure == nil)
        #expect(resolveCalls.last == 4)                          // the retry re-resolved the same track
        #expect(vm.selectedAudioTrack?.id == .jellyfinStream(4)) // and the pick stuck this time

        // Phase stays .loading (the scrim) until the reloaded stream's first beat.
        #expect(vm.phase == .loading)
        engine.push(.playing(100))
        try await engine.settle()
        #expect(vm.phase == .playing)
    }

    @Test("stop() clears a pending trackSwitchFailure")
    func stopClearsTrackSwitchFailure() async throws {
        let reporting = StubPlaybackReporting()
        let engine = FakePlaybackEngine(id: .avKit, capabilities: .avKit)
        let resolved = PlayerFixtures.resolvedMultiTrackTranscode()

        nonisolated(unsafe) var callCount = 0
        let vm = makePlayerVM(
            reporting: reporting,
            resolve: { _, _, _, _ in
                callCount += 1
                if callCount >= 2 { throw AppError.playback(.resourceUnavailable) }
                return resolved
            },
            engine: engine
        )
        await vm.start(item: PlayerFixtures.movieDetail())
        engine.push(.playing(100))
        try await engine.settle()

        let track = try #require(vm.availableAudioTracks.first { $0.id == .jellyfinStream(4) })
        await vm.selectAudioTrack(track)
        #expect(vm.trackSwitchFailure != nil)

        await vm.stop()
        #expect(vm.trackSwitchFailure == nil)
    }

    @Test("a .failed state clears isPlaying")
    func failedStateClearsIsPlaying() async throws {
        let reporting = StubPlaybackReporting()
        let engine = FakePlaybackEngine(id: .avKit, capabilities: .avKit)
        // `.mkv` is outside ReactiveFallback's MP4-family set, so `.assetNotPlayable`
        // stays terminal (no AVKit→VLC re-route) and we assert the real failed path.
        let resolved = PlayerFixtures.resolvedTranscodedMKV()
        let vm = makePlayerVM(reporting: reporting, engine: engine, resolved: resolved)
        await vm.start(item: PlayerFixtures.movieDetail())

        engine.push(.playing(10, duration: resolved.runtime!))
        try await engine.settle()
        #expect(vm.isPlaying == true)

        engine.push(.failed(.assetNotPlayable))
        try await engine.settle()
        #expect(vm.isPlaying == false)
        #expect(vm.phase == .failed(.playback(.decodeFailed)))
    }

    /// The load watchdog's expiry used to arrive as `.assetNotPlayable` and read "Couldn't
    /// decode this file" — an accusation against the file for what is almost always a slow
    /// server or a cold transcode, and the one message that sends the user looking in the
    /// wrong place. Same retryable scrim, honest sentence.
    @Test("a load timeout reads as a slow server, not a broken file")
    func loadTimeoutMapsToItsOwnMessage() async throws {
        let engine = FakePlaybackEngine(id: .avKit, capabilities: .avKit)
        let resolved = PlayerFixtures.resolvedTranscodedMKV()
        let vm = makePlayerVM(engine: engine, resolved: resolved)
        await vm.start(item: PlayerFixtures.movieDetail())

        engine.push(.failed(.loadTimedOut))
        try await engine.settle()

        #expect(vm.phase == .failed(.playback(.startupTimedOut)))
        #expect(vm.phase != .failed(.playback(.decodeFailed)))
    }

    @Test("start(itemID:) fetches the detail first, then plays it")
    func startByItemIDFetchesThenPlays() async {
        let reporting = StubPlaybackReporting()
        let engine = FakePlaybackEngine(id: .avKit, capabilities: .avKit)
        nonisolated(unsafe) var fetchedID: ItemID?
        let vm = makePlayerVM(
            reporting: reporting,
            resolve: { _, _, _, _ in PlayerFixtures.resolved() },
            engine: engine,
            fetchDetail: { id in fetchedID = id; return PlayerFixtures.movieDetail() }
        )
        await vm.start(itemID: ItemID(rawValue: "movie-1"))
        #expect(fetchedID == ItemID(rawValue: "movie-1"))
        #expect(!engine.loadedAssets.isEmpty)
    }

    @Test("start(itemID:) surfaces a fetch failure as .failed without resolving")
    func startByItemIDFetchFailure() async {
        let reporting = StubPlaybackReporting()
        let engine = FakePlaybackEngine(id: .avKit, capabilities: .avKit)
        nonisolated(unsafe) var didResolve = false
        let vm = makePlayerVM(
            reporting: reporting,
            resolve: { _, _, _, _ in didResolve = true; return PlayerFixtures.resolved() },
            engine: engine,
            fetchDetail: { _ in throw AppError.playback(.resourceUnavailable) }
        )
        await vm.start(itemID: ItemID(rawValue: "ep-1"))
        #expect(vm.phase == .failed(.playback(.resourceUnavailable)))
        #expect(didResolve == false)
        #expect(engine.loadedAssets.isEmpty)
    }

    @Test("exit during a slow resolve never builds or plays an engine")
    func exitDuringResolveNeverStartsPlayback() async throws {
        let reporting = StubPlaybackReporting()
        let engine = FakePlaybackEngine(id: .avKit, capabilities: .avKit)

        // A resolve that parks until the test releases it — the exit lands mid-resolve,
        // exactly like dismissing the player while the PlaybackInfo call is in flight.
        let (gate, gateContinuation) = AsyncStream<Void>.makeStream()
        nonisolated(unsafe) var engineBuilt = false
        let vm = makePlayerVM(
            reporting: reporting,
            resolve: { _, _, _, _ in
                for await _ in gate { break }
                return PlayerFixtures.resolved()
            },
            engineFactory: { _, _ in engineBuilt = true; return engine }
        )

        let startTask = Task { await vm.start(item: PlayerFixtures.movieDetail()) }
        try await Task.sleep(for: .milliseconds(20))   // let start() reach the resolve await
        vm.beginExit()
        await vm.stop()
        gateContinuation.yield(())                     // resolve returns AFTER the exit
        await startTask.value

        // The post-resolve fence must bail before the engine exists: no factory
        // call, no load, no play — nothing to resurrect audio on a dismissed player.
        #expect(engineBuilt == false)
        #expect(engine.loadedAssets.isEmpty)
        #expect(!engine.calls.contains("play"))
    }

    @Test("stop() is idempotent — exit trigger + onDisappear backstop tear down once")
    func doubleStopTearsDownOnce() async throws {
        let reporting = StubPlaybackReporting()
        let engine = FakePlaybackEngine(id: .avKit, capabilities: .avKit)
        let resolved = PlayerFixtures.resolved()
        let vm = makePlayerVM(reporting: reporting, engine: engine, resolved: resolved)
        await vm.start(item: PlayerFixtures.movieDetail())
        engine.push(.playing(30, duration: resolved.runtime!))
        try await engine.settle()

        // exitPlayer() fires stop() immediately; onDisappear fires it again as the
        // backstop. The second call must be a no-op.
        await vm.stop()
        await vm.stop()

        #expect(engine.calls.filter { $0 == "teardown" }.count == 1)
        let stoppedCount = (await reporting.events).filter { if case .stopped = $0 { return true } else { return false } }.count
        #expect(stoppedCount == 1)
    }

    @Test("retry() after a failed start disarms the exit fence and restarts playback")
    func retryDisarmsExitFence() async {
        let reporting = StubPlaybackReporting()
        let engine = FakePlaybackEngine(id: .avKit, capabilities: .avKit)

        nonisolated(unsafe) var resolveCalls = 0
        let vm = makePlayerVM(
            reporting: reporting,
            resolve: { _, _, _, _ in
                resolveCalls += 1
                if resolveCalls == 1 { throw AppError.playback(.resourceUnavailable) }
                return PlayerFixtures.resolved()
            },
            engine: engine
        )

        await vm.start(item: PlayerFixtures.movieDetail())
        #expect(vm.phase == .failed(.playback(.resourceUnavailable)))

        // retry() routes through stop(), which arms the exit fence — it must be
        // disarmed before the fresh start, or the restart dies at its first checkpoint.
        await vm.retry()
        #expect(resolveCalls == 2)
        #expect(!engine.loadedAssets.isEmpty)
        #expect(engine.calls.contains("play"))
    }

    // MARK: - NowPlaying (serialized — MPNowPlayingInfoCenter is a process-wide singleton)

    /// The VM-level cases drive a `SpyNowPlaying` — what the VM published is the contract,
    /// and asserting it through the live `MPNowPlayingInfoCenter` made them answerable by
    /// whatever else had touched the singleton. Only the two `NowPlayingController` cases
    /// below still read it, because for them the info center IS the subject under test;
    /// they are synchronous, and `.serialized` keeps them off each other's write.
    @Suite("NowPlaying", .serialized)
    @MainActor
    struct NowPlayingTests {
        @Test("PlayerViewModel publishes title/elapsed/rate to Now Playing on .playing")
        func vmPopulatesNowPlayingOnPlaying() async throws {
            let reporting = StubPlaybackReporting()
            let engine = FakePlaybackEngine(id: .avKit, capabilities: .avKit)
            let resolved = PlayerFixtures.resolved()
            let nowPlaying = SpyNowPlaying()
            let vm = makePlayerVM(reporting: reporting, engine: engine, resolved: resolved, nowPlaying: nowPlaying)
            await vm.start(item: PlayerFixtures.movieDetail(title: "Fixture Movie"))
            engine.push(.playing(30, duration: resolved.runtime!))
            try await engine.settle()
            let published = try #require(nowPlaying.updates.last)
            #expect(published.title == "Fixture Movie")
            #expect(CMTimeGetSeconds(published.position) > 0.0)
            #expect(published.isPlaying)
            await vm.stop()
        }

        @Test("PlayerViewModel publishes a stopped rate to Now Playing on .paused")
        func vmSetsNowPlayingRateZeroOnPaused() async throws {
            let reporting = StubPlaybackReporting()
            let engine = FakePlaybackEngine(id: .avKit, capabilities: .avKit)
            let resolved = PlayerFixtures.resolved()
            let nowPlaying = SpyNowPlaying()
            let vm = makePlayerVM(reporting: reporting, engine: engine, resolved: resolved, nowPlaying: nowPlaying)
            await vm.start(item: PlayerFixtures.movieDetail(title: "Fixture Movie"))
            engine.push(.playing(10, duration: resolved.runtime!))
            engine.push(.paused(10, duration: resolved.runtime!))
            try await engine.settle()
            let published = try #require(nowPlaying.updates.last)
            #expect(!published.isPlaying)
            await vm.stop()
        }

        @Test("PlayerViewModel clears Now Playing on stop()")
        func vmClearsNowPlayingOnStop() async throws {
            let reporting = StubPlaybackReporting()
            let engine = FakePlaybackEngine(id: .avKit, capabilities: .avKit)
            let resolved = PlayerFixtures.resolved()
            let nowPlaying = SpyNowPlaying()
            let vm = makePlayerVM(reporting: reporting, engine: engine, resolved: resolved, nowPlaying: nowPlaying)
            await vm.start(item: PlayerFixtures.movieDetail(title: "Fixture Movie"))
            engine.push(.playing(10, duration: resolved.runtime!))
            try await engine.settle()
            #expect(nowPlaying.clearCount == 0)
            await vm.stop()
            #expect(nowPlaying.clearCount == 1)
        }

        @Test("NowPlayingController.update writes elapsed/duration/rate into MPNowPlayingInfoCenter.default")
        func nowPlayingUpdate() {
            let controller = NowPlayingController()
            controller.update(position: CMTime(seconds: 60, preferredTimescale: 600),
                              duration: CMTime(seconds: 7200, preferredTimescale: 600),
                              isPlaying: true, title: "Test Movie")
            let info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
            #expect((info[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double) == 60.0)
            #expect((info[MPMediaItemPropertyPlaybackDuration] as? Double) == 7200.0)
            #expect((info[MPNowPlayingInfoPropertyPlaybackRate] as? Double) == 1.0)
            #expect((info[MPMediaItemPropertyTitle] as? String) == "Test Movie")
        }

        @Test("NowPlayingController.update sets rate 0 when paused")
        func nowPlayingPaused() {
            let controller = NowPlayingController()
            controller.update(position: CMTime(seconds: 120, preferredTimescale: 600),
                              duration: CMTime(seconds: 7200, preferredTimescale: 600),
                              isPlaying: false, title: "Test Movie")
            let info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
            #expect((info[MPNowPlayingInfoPropertyPlaybackRate] as? Double) == 0.0)
            #expect((info[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double) == 120.0)
        }
    }

    /// The SMB thumbnail backfill seam (`scheduleThumbnailBackfill()`, `backfillThumbnail`,
    /// `backfillDelay`): a session's first `.playing` beat schedules a low-priority, delayed
    /// frame capture that lands in the app's `MediaArtworkProvider` sink — see
    /// `PlayerViewModel.scheduleThumbnailBackfill()`. These tests drive the seam directly
    /// (never a real `MediaArtworkProvider`) with a short injected `backfillDelay` so nothing
    /// here waits wall-clock seconds for the real 8s default.
    @Suite("SMB thumbnail backfill")
    @MainActor
    struct SMBThumbnailBackfillTests {
        /// Records every `backfillThumbnail` invocation the VM drives — the `duration`/
        /// `performsIO` arguments, plus whatever the test's own closure got back from calling
        /// the injected `captureFrame`. Actor-isolated: the VM calls in from its own low-priority
        /// backfill `Task`, off the MainActor test body.
        private actor BackfillRecorder {
            private(set) var invocations: [(duration: Duration?, performsIO: Bool, data: Data?)] = []

            func record(duration: Duration?, performsIO: Bool, data: Data?) {
                invocations.append((duration, performsIO, data))
            }
        }

        /// Polls until `recorder` has at least one invocation or `timeout` passes. The backfill
        /// fires from a detached `Task` the beat handler never awaits, so `engine.settle()` alone
        /// only proves the beat was consumed — not that the (short, injected) delay has elapsed.
        /// Used by the negative cases too: it returns the INSTANT anything is recorded, so a
        /// regression reports immediately instead of riding out a fixed sleep. The ceiling is an
        /// anti-hang bound, so it scales for oversubscribed CI runners.
        private func waitForBackfill(
            _ recorder: BackfillRecorder,
            timeout: Duration = CITimeScale.seconds(2)
        ) async {
            let deadline = ContinuousClock.now.advanced(by: timeout)
            while await recorder.invocations.isEmpty, ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(10))
            }
        }

        /// The one `backfillThumbnail` sink these tests install: forwards the arguments the VM
        /// passed, plus whatever the VM's own capture closure returns, into `recorder`.
        private func recordingSink(
            into recorder: BackfillRecorder
        ) -> @Sendable (Duration?, Bool, @escaping @Sendable () async -> Data?) async -> Void {
            { duration, performsIO, captureFrame in
                await recorder.record(
                    duration: duration, performsIO: performsIO, data: await captureFrame())
            }
        }

        /// `makeVM` with the shared recording sink already wired — what every SMB case here wants.
        private func makeVM(
            engine: FakePlaybackEngine,
            recorder: BackfillRecorder,
            backfillDelay: Duration = .milliseconds(5)
        ) -> PlayerViewModel {
            makeVM(
                engine: engine,
                backfillDelay: backfillDelay,
                backfillThumbnail: recordingSink(into: recorder)
            )
        }

        /// A `PlayerViewModel` on the SMB path with both backfill seams injectable — mirrors
        /// `SMBPlaybackStartTests.makeVM` but exposes `backfillThumbnail`/`backfillDelay`, which
        /// that suite predates.
        private func makeVM(
            engine: FakePlaybackEngine,
            backfillDelay: Duration = .milliseconds(5),
            backfillThumbnail: @escaping @Sendable (Duration?, Bool, @escaping @Sendable () async -> Data?) async -> Void = { _, _, _ in }
        ) -> PlayerViewModel {
            PlayerViewModel(
                deviceProfileBuilder: makeTestDeviceProfileBuilder(),
                playbackInfo: StubPlaybackReporting(),
                resolve: { _, _, _, _ in
                    Issue.record("SMB playback must not call the Jellyfin resolve")
                    throw AppError.playback(.unsupportedFormat)
                },
                engineFactory: { _, _ in engine },
                audioSession: NoopAudioSession(),
                subtitleFetch: { _ in nil },
                smbResumeStore: SMBTestFixtures.inertResumeStore(),
                backfillThumbnail: backfillThumbnail,
                backfillDelay: backfillDelay
            )
        }

        private func smbItem(hasTrustworthyDuration: Bool = true) -> SMBPlaybackItem {
            SMBPlaybackItem(
                itemID: ItemID(rawValue: "smb-backfill-item"),
                url: URL(string: "smb://nas.local/Media/Movies/Backfill.mkv")!,
                title: "Backfill",
                vlcOptions: [],
                hasTrustworthyDuration: hasTrustworthyDuration
            )
        }

        @Test("an SMB session's first .playing beat schedules exactly one backfill; a second .playing beat schedules none")
        func firstPlayingBeatSchedulesExactlyOneBackfill() async throws {
            let engine = FakePlaybackEngine(id: .vlcKit, capabilities: .vlcKit)
            // Flipped off the fake's default so the assertion below can't pass on `true == true`:
            // the sink must report what THIS engine says, not the protocol default.
            engine.captureFramePerformsIO = false
            let recorder = BackfillRecorder()
            let vm = makeVM(engine: engine, recorder: recorder)

            await vm.start(smbItem: smbItem())
            engine.push(.playing(1, duration: .seconds(6000)))
            engine.push(.playing(2, duration: .seconds(6000)))
            try await engine.settle()

            await waitForBackfill(recorder)

            let invocations = await recorder.invocations
            #expect(invocations.count == 1)
            // Threaded straight from `engine.captureFramePerformsIO`: the sink gates an I/O-issuing
            // capture off non-LAN links, so a hardcoded value here would be a silent policy bypass.
            #expect(invocations.first?.performsIO == false)
        }

        @Test("the engine's captured frame reaches the backfill sink's capture closure after the injected delay")
        func capturedFrameReachesSinkAfterDelay() async throws {
            let engine = FakePlaybackEngine(id: .vlcKit, capabilities: .vlcKit)
            let frame = Data([0xAA, 0xBB, 0xCC])
            engine.captureFrameResult = frame
            let recorder = BackfillRecorder()
            let vm = makeVM(engine: engine, recorder: recorder)

            await vm.start(smbItem: smbItem())
            engine.push(.playing(1, duration: .seconds(6000)))
            try await engine.settle()

            await waitForBackfill(recorder)

            #expect(await recorder.invocations.first?.data == frame)
            #expect(engine.calls.contains("captureFrame"))
        }

        /// Two independent protections, either of which alone would hold: `stop()` cancels the
        /// pending backfill `Task` outright, and it also nils the SMB session — which the task
        /// re-reads AFTER its sleep, so even a cancel that lost the race finds nothing to capture
        /// for. (`tearDownEngine()`, which `stop()` also runs, cancels the task as well, so a
        /// reactive engine rebuild can't burn the session's one shot either.)
        @Test("stop() before the backfill delay fires prevents any store")
        func stopBeforeDelayPreventsStore() async throws {
            let engine = FakePlaybackEngine(id: .vlcKit, capabilities: .vlcKit)
            let recorder = BackfillRecorder()
            // `stop()` has to land inside this window in WALL-CLOCK time, against a `.low`-priority
            // sleep — so the window scales for oversubscribed runners rather than flaking on them.
            let delay = Duration.milliseconds(Int(500 * CITimeScale.factor))
            let vm = makeVM(engine: engine, recorder: recorder, backfillDelay: delay)

            await vm.start(smbItem: smbItem())
            engine.push(.playing(1, duration: .seconds(6000)))
            try await engine.settle()

            // Well within the delay — the pending backfill Task must not survive this.
            await vm.stop()

            // Polls well past the delay, returning early the moment anything IS recorded.
            await waitForBackfill(recorder, timeout: delay * 3)
            #expect(await recorder.invocations.isEmpty)
        }

        @Test("a non-SMB (Jellyfin) session never invokes the backfill sink")
        func nonSMBSessionNeverInvokesBackfill() async throws {
            let engine = FakePlaybackEngine(id: .avKit, capabilities: .avKit)
            let resolved = PlayerFixtures.resolved()
            let recorder = BackfillRecorder()
            let vm = PlayerViewModel(
                deviceProfileBuilder: makeTestDeviceProfileBuilder(),
                playbackInfo: StubPlaybackReporting(),
                resolve: { _, _, _, _ in resolved },
                engineFactory: { _, _ in engine },
                audioSession: NoopAudioSession(),
                backfillThumbnail: recordingSink(into: recorder),
                backfillDelay: .milliseconds(5)
            )

            await vm.start(item: PlayerFixtures.movieDetail())
            engine.push(.playing(10, duration: resolved.runtime!))
            try await engine.settle()

            // Polls far past the (short) delay, had a backfill been scheduled — the gate is
            // `smbSession != nil`, which a Jellyfin session never sets.
            await waitForBackfill(recorder, timeout: .milliseconds(Int(500 * CITimeScale.factor)))
            #expect(await recorder.invocations.isEmpty)
        }

        @Test("an untrustworthy duration is never carried into the backfill sink")
        func untrustworthyDurationStoresNilDuration() async throws {
            let engine = FakePlaybackEngine(id: .vlcKit, capabilities: .vlcKit)
            let recorder = BackfillRecorder()
            let vm = makeVM(engine: engine, recorder: recorder)

            await vm.start(smbItem: smbItem(hasTrustworthyDuration: false))
            // Numeric, real-looking duration — proving the nil comes from the trust bit, not
            // from `hasKnownDuration` being false too.
            engine.push(.playing(1, duration: .seconds(6000)))
            try await engine.settle()

            await waitForBackfill(recorder)

            #expect(await recorder.invocations.first?.duration == nil)
        }
    }
}

/// Who renders which subtitle stream on a Jellyfin DIRECT PLAY session. A text stream
/// has a sidecar URL, so we fetch and draw it ourselves; an image stream has none, so
/// the only thing that can draw it locally is the engine — and blinding the engine
/// (`:no-spu`) to protect the sidecars would silently cost the user those tracks.
@Suite("PlayerViewModel — direct-play subtitle ownership", .serialized)
@MainActor
struct DirectPlaySubtitleOwnershipTests {

    /// Starts a session and hands the VM the engine inventory a direct-play demux would
    /// report — one engine track per subtitle stream, in the engine's own id namespace.
    private func startedVM(
        _ resolved: ResolvedPlayback,
        engine: FakePlaybackEngine,
        selecting engineSelection: TrackID? = nil
    ) async throws -> PlayerViewModel {
        let vm = makePlayerVM(resolve: { _, _, _, _ in resolved }, engine: engine)
        await vm.start(item: PlayerFixtures.movieDetail())
        var inventory = PlayerFixtures.engineSubtitleInventory(for: resolved)
        if let engineSelection {
            inventory = TrackInventory(audio: inventory.audio, subtitles: inventory.subtitles,
                                       selectedSubtitleID: engineSelection)
        }
        engine.push(.ready(duration: resolved.runtime!, tracks: inventory))
        try await engine.settle()
        return vm
    }

    @Test("an image-only item keeps the ENGINE's row and leaves its SPU renderer on")
    func imageOnlyKeepsTheEngineRow() async throws {
        let engine = FakePlaybackEngine(id: .vlcKit, capabilities: .vlcKit)
        let resolved = PlayerFixtures.resolvedDirectPlaySubtitleMix(image: [2: "eng"])
        let vm = try await startedVM(resolved, engine: engine)

        #expect(resolved.clientRendersAllSubtitles == false)
        #expect(engine.loadedAssets.first?.engineSubtitlesDisabled == false)
        #expect(vm.availableSubtitleTracks.count == 1)
        let row = try #require(vm.availableSubtitleTracks.first)
        #expect(row.id == .vlc("vlc-s2"))   // the engine draws it — locally, for free
        #expect(row.isBurnedIn == false)    // no server re-encode earned
        #expect(row.displayName == "English")   // the server's menu label, not the engine's "PGS"
    }

    @Test("a text-only item becomes a client-drawn sidecar row and blinds the engine")
    func textOnlyGoesToTheSidecar() async throws {
        let engine = FakePlaybackEngine(id: .vlcKit, capabilities: .vlcKit)
        let resolved = PlayerFixtures.resolvedDirectPlaySubtitleMix(text: [2: "eng"])
        let vm = try await startedVM(resolved, engine: engine)

        #expect(resolved.clientRendersAllSubtitles == true)
        #expect(engine.loadedAssets.first?.engineSubtitlesDisabled == true)
        #expect(vm.availableSubtitleTracks.map(\.id) == [.jellyfinStream(2)])
    }

    @Test("a mixed item routes each stream to the renderer that can actually draw it")
    func mixedRoutesPerStream() async throws {
        let engine = FakePlaybackEngine(id: .vlcKit, capabilities: .vlcKit)
        let resolved = PlayerFixtures.resolvedDirectPlaySubtitleMix(
            text: [2: "eng"], image: [3: "jpn"]
        )
        let vm = try await startedVM(resolved, engine: engine)

        #expect(resolved.clientRendersAllSubtitles == false)
        #expect(engine.loadedAssets.first?.engineSubtitlesDisabled == false)
        #expect(vm.availableSubtitleTracks.map(\.id) == [.jellyfinStream(2), .vlc("vlc-s3")])
        #expect(vm.availableSubtitleTracks.allSatisfy { !$0.isBurnedIn })
    }

    /// Two same-language streams make the engine↔stream join ambiguous, so the image
    /// one loses its engine row. Degraded (a burn-in costs a full re-encode), never
    /// wrong — the alternative is offering the SRT's engine track under the PGS's name.
    @Test("an image stream the engine can't be matched to falls back to server burn-in")
    func unmatchedImageFallsBackToBurnIn() async throws {
        let engine = FakePlaybackEngine(id: .vlcKit, capabilities: .vlcKit)
        let resolved = PlayerFixtures.resolvedDirectPlaySubtitleMix(
            text: [2: "eng"], image: [3: "eng"]
        )
        let vm = try await startedVM(resolved, engine: engine)

        #expect(vm.availableSubtitleTracks.map(\.id) == [.jellyfinStream(2), .jellyfinStream(3)])
        #expect(try #require(vm.availableSubtitleTracks.last).isBurnedIn)
    }

    @Test("the engine's own pick is adopted when the engine is what draws it")
    func enginePickIsAdoptedWhenTheEngineDraws() async throws {
        let engine = FakePlaybackEngine(id: .vlcKit, capabilities: .vlcKit)
        let resolved = PlayerFixtures.resolvedDirectPlaySubtitleMix(image: [2: "eng"])
        let vm = try await startedVM(resolved, engine: engine, selecting: .vlc("vlc-s2"))

        #expect(vm.selectedSubtitleTrack?.id == .vlc("vlc-s2"))
        // Nothing was commanded at all — the engine's own pick stands. Matched on the
        // whole family of calls, not the one literal: a fake that reformats its log
        // would make a single-string negative pass forever.
        #expect(engine.calls.contains { $0.hasPrefix("setSubtitleTrack") } == false)
    }

    /// The one shape `:no-spu` cannot cover: the item has an image sub, so the engine's
    /// renderer stays on — and VLC then auto-selects a text track we are drawing
    /// ourselves, painting a second copy under the overlay.
    @Test("the engine's pick of a stream WE draw is deselected, never adopted")
    func enginePickOfAClientDrawnStreamIsDeselected() async throws {
        let engine = FakePlaybackEngine(id: .vlcKit, capabilities: .vlcKit)
        let resolved = PlayerFixtures.resolvedDirectPlaySubtitleMix(
            text: [2: "eng"], image: [3: "jpn"]
        )
        let vm = try await startedVM(resolved, engine: engine, selecting: .vlc("vlc-s2"))

        #expect(vm.selectedSubtitleTrack == nil)
        #expect(engine.calls.contains("setSubtitleTrack(nil)"))
    }

    /// The regression: the server's default is a STREAM index, and the row that renders
    /// an image stream carries the ENGINE's id — so matching `.jellyfinStream(index)`
    /// found nothing and a PGS default was silently dropped on every first play.
    @Test("a server default that points at an engine-rendered image sub is selected")
    func imageDefaultSelectsTheEngineRow() async throws {
        let engine = FakePlaybackEngine(id: .vlcKit, capabilities: .vlcKit)
        let resolved = PlayerFixtures.resolvedDirectPlaySubtitleMix(
            image: [2: "eng"], defaultSubtitleStreamIndex: 2
        )
        let vm = try await startedVM(resolved, engine: engine)

        #expect(vm.selectedSubtitleTrack?.id == .vlc("vlc-s2"))
        #expect(engine.selectedSubtitleTrackID == .vlc("vlc-s2"))
    }

    /// Burn-in stays opt-in. The engine can't be joined to this image stream (two
    /// same-language streams), so its only delivery is a full server re-encode — which
    /// a preference must never trigger on its own.
    @Test("a server default that only server burn-in can deliver is left alone")
    func burnInDefaultIsNotAutoApplied() async throws {
        let engine = FakePlaybackEngine(id: .vlcKit, capabilities: .vlcKit)
        let resolved = PlayerFixtures.resolvedDirectPlaySubtitleMix(
            text: [2: "eng"], image: [3: "eng"], defaultSubtitleStreamIndex: 3
        )
        let vm = try await startedVM(resolved, engine: engine)

        #expect(try #require(vm.availableSubtitleTracks.last).isBurnedIn)
        #expect(vm.selectedSubtitleTrack == nil)
    }

    /// The sidecar half of the same join, so the fix can't be read as "engine rows only".
    @Test("a server default that points at a client-drawn text sub still fetches it")
    func textDefaultStillGoesToTheSidecar() async throws {
        let engine = FakePlaybackEngine(id: .vlcKit, capabilities: .vlcKit)
        let resolved = PlayerFixtures.resolvedDirectPlaySubtitleMix(
            text: [2: "eng"], image: [3: "jpn"], defaultSubtitleStreamIndex: 2
        )
        let vm = try await startedVM(resolved, engine: engine)
        await vm.debugAwaitSubtitleFetch()

        #expect(vm.selectedSubtitleTrack?.id == .jellyfinStream(2))
        // The client draws it, so the engine's own subtitle is held off.
        #expect(engine.calls.contains("setSubtitleTrack(nil)"))
    }

    /// The engine-facing font knobs follow the user's design. Both are libvlc MEDIA
    /// options, fixed for the life of the decoder — hence sampled once, at asset build.
    @Test("the asset carries the user's subtitle design", arguments: SubtitleFontDesign.allCases)
    func assetCarriesTheFontDesign(design: SubtitleFontDesign) async throws {
        let engine = FakePlaybackEngine(id: .vlcKit, capabilities: .vlcKit)
        let resolved = PlayerFixtures.resolvedDirectPlaySubtitleMix(image: [2: "eng"])
        let vm = makePlayerVM(
            resolve: { _, _, _, _ in resolved }, engine: engine,
            subtitleStyle: { .standard.with { $0.fontDesign = design } }
        )
        await vm.start(item: PlayerFixtures.movieDetail())

        let asset = try #require(engine.loadedAssets.first)
        #expect(asset.subtitleFontFamily == VLCSubtitleFonts.freetypeFamily(for: design.bundleDesign))
        // Whatever directory it names, it is the one built for THIS design (or the
        // bundle fallback, which is design-agnostic) — never the other design's.
        let directory = try #require(asset.subtitleFontsDirectory)
        #expect(directory.lastPathComponent != (design == .serif ? "sans" : "serif"))
    }
}

/// The sidecar fetch can take seconds (a cold embedded Jellyfin stream is extracted by
/// ffmpeg on first request), and the panel the pick was made from closes on the same
/// turn as the tap. So the affordance is armed SYNCHRONOUSLY, by its own method, and
/// these tests call it exactly the way the view does — with no `await` in sight.
@Suite("PlayerViewModel — sidecar fetch indicator", .serialized)
@MainActor
struct SidecarFetchIndicatorTests {

    private func startedVM(_ engine: FakePlaybackEngine) async throws -> PlayerViewModel {
        let resolved = PlayerFixtures.resolvedDirectPlayEmbeddedSubs()
        let vm = makePlayerVM(resolve: { _, _, _, _ in resolved }, engine: engine)
        await vm.start(item: PlayerFixtures.movieDetail())
        engine.push(.ready(duration: resolved.runtime!, tracks: TrackInventory(audio: [], subtitles: [])))
        try await engine.settle()
        return vm
    }

    private func row(_ vm: PlayerViewModel, _ id: TrackID) throws -> SubtitleTrack {
        try #require(vm.availableSubtitleTracks.first { $0.id == id })
    }

    @Test("arming is synchronous — the state is set with no await in between")
    func armingIsSynchronous() async throws {
        let vm = try await startedVM(FakePlaybackEngine(id: .vlcKit, capabilities: .vlcKit))
        let track = try row(vm, .jellyfinStream(2))

        vm.armSubtitleFetchIndicator(for: track)

        #expect(vm.loadingSubtitleTrackID == .jellyfinStream(2))
    }

    @Test("nothing is armed for Off or for a burn-in pick")
    func nothingArmedForOffOrBurnIn() async throws {
        let vm = try await startedVM(FakePlaybackEngine(id: .vlcKit, capabilities: .vlcKit))

        vm.armSubtitleFetchIndicator(for: nil)
        #expect(vm.loadingSubtitleTrackID == nil)

        vm.armSubtitleFetchIndicator(for: try row(vm, .jellyfinStream(3)))   // PGS, burn-in
        #expect(vm.loadingSubtitleTrackID == nil)
    }

    @Test("a re-pick of an already-fetched track shows nothing — it is instant")
    func cachedPickDoesNotArm() async throws {
        let engine = FakePlaybackEngine(id: .vlcKit, capabilities: .vlcKit)
        let vm = try await startedVM(engine)
        let track = try row(vm, .jellyfinStream(2))

        await vm.selectSubtitleTrack(track)
        await vm.debugAwaitSubtitleFetch()
        await vm.selectSubtitleTrack(nil)

        vm.armSubtitleFetchIndicator(for: track)
        #expect(vm.loadingSubtitleTrackID == nil)
    }

    /// The fetch owns the indicator while it runs: a programmatic pick never goes
    /// through the view's arm, so `loadSidecarSubtitle` has to claim the slot itself.
    /// A fetch that never returns pins the in-flight window open so the state can be
    /// observed from outside the call.
    @Test("an in-flight fetch shows as loading with no renderer installed yet")
    func inFlightFetchShowsAsLoading() async throws {
        let engine = FakePlaybackEngine(id: .vlcKit, capabilities: .vlcKit)
        let resolved = PlayerFixtures.resolvedDirectPlayEmbeddedSubs()
        let fetchEntered = AsyncStream<Void>.makeStream()
        let vm = makePlayerVM(
            resolve: { _, _, _, _ in resolved },
            engine: engine,
            subtitleFetch: { _ in
                fetchEntered.continuation.yield()
                try? await Task.sleep(for: .seconds(60))   // parked for the test's lifetime
                return nil
            }
        )
        await vm.start(item: PlayerFixtures.movieDetail())
        engine.push(.ready(duration: resolved.runtime!, tracks: TrackInventory(audio: [], subtitles: [])))
        try await engine.settle()
        let track = try row(vm, .jellyfinStream(2))

        let selection = Task { await vm.selectSubtitleTrack(track) }
        var entered = fetchEntered.stream.makeAsyncIterator()
        _ = await entered.next()

        #expect(vm.loadingSubtitleTrackID == .jellyfinStream(2))
        #expect(vm.subtitleRenderer == nil)
        selection.cancel()
    }

    /// The chip never disables while it spins, so the user can reopen the menu and pick
    /// again mid-fetch. That second pick has to WIN: cancel the cold extract still in
    /// flight (a stale sidecar landing later would draw the wrong language over the new
    /// pick) and take the loading slot for itself.
    @Test("a pick made mid-fetch cancels the first fetch and takes the loading slot")
    func secondPickCancelsTheInFlightFetch() async throws {
        let engine = FakePlaybackEngine(id: .vlcKit, capabilities: .vlcKit)
        let resolved = PlayerFixtures.resolvedDirectPlayEmbeddedSubs()
        let slowEntered = AsyncStream<Void>.makeStream()
        let slowCancelled = AsyncStream<Void>.makeStream()
        // The second fetch parks on a gate the test opens by hand: without it, its own
        // completion could clear the loading slot before the assertion reads it.
        let secondGate = AsyncStream<Void>.makeStream()
        let vm = makePlayerVM(
            resolve: { _, _, _, _ in resolved },
            engine: engine,
            subtitleFetch: { url in
                guard url.path.contains("/Subtitles/2/") else {
                    var gate = secondGate.stream.makeAsyncIterator()
                    _ = await gate.next()
                    return Data()
                }
                slowEntered.continuation.yield()
                try? await Task.sleep(for: .seconds(60))
                if Task.isCancelled { slowCancelled.continuation.yield() }
                return nil
            }
        )
        await vm.start(item: PlayerFixtures.movieDetail())
        engine.push(.ready(duration: resolved.runtime!, tracks: TrackInventory(audio: [], subtitles: [])))
        try await engine.settle()
        let slow = try row(vm, .jellyfinStream(2))
        let second = try row(vm, .jellyfinStream(4))

        await vm.selectSubtitleTrack(slow)
        var entered = slowEntered.stream.makeAsyncIterator()
        _ = await entered.next()
        #expect(vm.loadingSubtitleTrackID == .jellyfinStream(2))

        await vm.selectSubtitleTrack(second)
        var cancelled = slowCancelled.stream.makeAsyncIterator()
        _ = await cancelled.next()
        // The chip's label and its spinner agree on the SECOND track, not the abandoned one.
        #expect(vm.selectedSubtitleTrack == second)
        #expect(vm.loadingSubtitleTrackID == .jellyfinStream(4))

        secondGate.continuation.yield()
        await vm.debugAwaitSubtitleFetch()
        #expect(vm.loadingSubtitleTrackID == nil)
    }

    @Test("the indicator clears once the fetch resolves")
    func indicatorClearsWhenTheFetchLands() async throws {
        let engine = FakePlaybackEngine(id: .vlcKit, capabilities: .vlcKit)
        let vm = try await startedVM(engine)
        let track = try row(vm, .jellyfinStream(2))

        vm.armSubtitleFetchIndicator(for: track)
        #expect(vm.loadingSubtitleTrackID == .jellyfinStream(2))

        await vm.selectSubtitleTrack(track)
        await vm.debugAwaitSubtitleFetch()

        #expect(vm.loadingSubtitleTrackID == nil)
    }
}

/// The subtitle-delay nudge is the USER's intent for an ITEM; the engine's copy is
/// scoped to the input `load()` just replaced. So the view model holds it and re-pushes
/// it, and an episode change starts level.
@Suite("PlayerViewModel — subtitle delay ownership", .serialized)
@MainActor
struct SubtitleDelayOwnershipTests {

    @Test("a same-item reload re-applies the delay onto the fresh input")
    func reloadReappliesTheDelay() async throws {
        let engine = FakePlaybackEngine(id: .avKit, capabilities: .avKit)
        let resolved = PlayerFixtures.resolvedMultiTrackTranscode()
        let vm = makePlayerVM(resolve: { _, _, _, _ in resolved }, engine: engine)
        await vm.start(item: PlayerFixtures.movieDetail())
        await vm.setSubtitleDelay(ms: -2000)
        #expect(vm.subtitleDelayMs == -2000)

        // A transcode audio switch reloads the SAME item on the reused engine.
        await vm.selectAudioTrack(try #require(vm.availableAudioTracks.last))

        #expect(engine.calls.filter { $0 == "setSubtitleDelay(-2000)" }.count == 2)
    }

    @Test("a fresh session never pushes a delay the user didn't ask for")
    func freshSessionPushesNothing() async throws {
        let engine = FakePlaybackEngine(id: .avKit, capabilities: .avKit)
        let resolved = PlayerFixtures.resolvedMultiTrackTranscode()
        let vm = makePlayerVM(resolve: { _, _, _, _ in resolved }, engine: engine)
        await vm.start(item: PlayerFixtures.movieDetail())

        #expect(vm.subtitleDelayMs == 0)
        #expect(engine.calls.contains { $0.hasPrefix("setSubtitleDelay") } == false)
    }
}
