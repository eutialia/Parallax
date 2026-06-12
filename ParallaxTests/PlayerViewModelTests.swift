import Foundation
import CoreMedia
import MediaPlayer
import Testing
@testable import Parallax
import ParallaxPlayback
import ParallaxPlaybackTestSupport
@testable import ParallaxJellyfin
@testable import ParallaxCore

// .serialized is required because several tests write to MPNowPlayingInfoCenter.default(),
// which is a process-wide singleton. Parallel async tests interleave at `await` points
// and clobber each other's nowPlayingInfo state even when the NowPlaying sub-suite itself
// is serialized, because outer-suite tests (e.g. teardownReportsStopped calling vm.stop()
// → nowPlaying.clear()) run concurrently with the inner suite.
@Suite("PlayerViewModel integration", .serialized)
@MainActor
struct PlayerViewModelTests {
    /// Builds a VM wired to a FakePlaybackEngine + recording reporting stub +
    /// a resolve closure that captures the item id and returns a canned
    /// ResolvedPlayback.
    private func makeVM(
        reporting: StubPlaybackReporting,
        engine: FakePlaybackEngine,
        resolved: ResolvedPlayback,
        audioSession: any AudioSessionControlling = NoopAudioSession(),
        capturedItem: @escaping @Sendable (ItemID) -> Void
    ) -> PlayerViewModel {
        let probe = FakeCapabilityProbe(hdr: .none, audioOutput: .stereo)
        let builder = DeviceProfileBuilder(probe: probe)
        return PlayerViewModel(
            deviceProfileBuilder: builder,
            playbackInfo: reporting,
            resolve: { id, _, _, _, _ in
                capturedItem(id)
                return resolved
            },
            engineFactory: { _ in engine },
            audioSession: audioSession
        )
    }

    @Test("resolves, selects .avKit, loads + plays, maps states, emits beats in order")
    func happyPath() async throws {
        let reporting = StubPlaybackReporting()
        let engine = FakePlaybackEngine(id: .avKit, capabilities: .avKit)
        let resolved = PlayerFixtures.resolved()
        var resolvedItemID: ItemID?

        let vm = makeVM(
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
        engine.push(.playing(position: CMTime(seconds: 10, preferredTimescale: 1), duration: resolved.runtime!, buffered: nil))
        engine.push(.playing(position: CMTime(seconds: 20, preferredTimescale: 1), duration: resolved.runtime!, buffered: nil))
        engine.push(.ended)
        engine.finish()

        // Let the consumer Task drain the scripted states.
        try await Task.sleep(for: .milliseconds(50))

        #expect(vm.phase == .playing)

        let events = await reporting.events
        #expect(events == [
            .start(ticks: 10 * 10_000_000, isPaused: false, itemID: "movie-1"),
            .progress(ticks: 20 * 10_000_000, isPaused: false, itemID: "movie-1"),
            .stopped(ticks: 20 * 10_000_000, itemID: "movie-1"),
        ])
    }

    @Test("audio session activation failure surfaces a distinct error and short-circuits before resolve")
    func audioSessionFailureIsDistinctAndShortCircuits() async {
        let reporting = StubPlaybackReporting()
        let engine = FakePlaybackEngine(id: .avKit, capabilities: .avKit)
        var didResolve = false

        let vm = makeVM(
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

    @Test("transcoded MKV plays via AVKit — selector gates on the delivered HLS, not the source container")
    func transcodedMKVSelectsAVKit() async {
        let reporting = StubPlaybackReporting()
        let engine = FakePlaybackEngine(id: .avKit, capabilities: .avKit)

        let vm = makeVM(
            reporting: reporting,
            engine: engine,
            resolved: PlayerFixtures.resolvedTranscodedMKV(),
            capturedItem: { _ in }
        )

        await vm.start(item: PlayerFixtures.movieDetail())

        // Source is MKV/AV1/DTS, but the transcode delivery is HLS → AVKit.
        #expect(vm.phase != .failed(.playback(.unsupportedFormat)))
        #expect(!engine.loadedAssets.isEmpty)
        #expect(engine.loadedAssets.first?.hints.container == .hls)
        #expect(engine.calls.contains("play"))
    }

    @Test("teardown reports stopped and finishes the engine")
    func teardownReportsStopped() async throws {
        let reporting = StubPlaybackReporting()
        let engine = FakePlaybackEngine(id: .avKit, capabilities: .avKit)
        let resolved = PlayerFixtures.resolved()

        let vm = makeVM(reporting: reporting, engine: engine, resolved: resolved, capturedItem: { _ in })
        await vm.start(item: PlayerFixtures.movieDetail())
        engine.push(.playing(position: CMTime(seconds: 30, preferredTimescale: 1), duration: resolved.runtime!, buffered: nil))
        try await Task.sleep(for: .milliseconds(50))

        await vm.stop()
        #expect(engine.calls.contains("teardown"))

        let events = await reporting.events
        #expect(events.contains(.stopped(ticks: 30 * 10_000_000, itemID: "movie-1")))
    }

    @Test("VC-1 MKV direct-play routes to .vlcKit — no unsupportedFormat error")
    func vc1MKVDirectPlaySelectsVLCKit() async {
        let reporting = StubPlaybackReporting()
        let engine = FakePlaybackEngine(id: .vlcKit, capabilities: .vlcKit)

        let vm = makeVM(
            reporting: reporting,
            engine: engine,
            resolved: PlayerFixtures.resolvedVC1MKV(),
            capturedItem: { _ in }
        )

        await vm.start(item: PlayerFixtures.movieDetail())

        // The guard is gone; .vlcKit is now a valid path. The factory closure
        // { _ in engine } returns the fake regardless of id — the point is that
        // start() does NOT short-circuit with unsupportedFormat.
        #expect(vm.phase != .failed(.playback(.unsupportedFormat)))
        #expect(engine.loadedAssets.first != nil)
        #expect(engine.loadedAssets.first?.hints.container == .mkv)
        #expect(engine.loadedAssets.first?.hints.videoCodec == .vc1)
        #expect(engine.calls.contains("play"))
    }

    @Test("availableAudio/SubtitleTracks start empty and populate on .ready")
    func trackStatePopulatesOnReady() async throws {
        let reporting = StubPlaybackReporting()
        let engine = FakePlaybackEngine(id: .avKit, capabilities: .avKit)
        let vm = makeVM(reporting: reporting, engine: engine, resolved: PlayerFixtures.resolved(), capturedItem: { _ in })
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
        try await Task.sleep(for: .milliseconds(50))

        #expect(vm.availableAudioTracks.count == 2)
        #expect(vm.availableSubtitleTracks.count == 1)
        #expect(vm.selectedAudioTrack == nil)
        #expect(vm.selectedSubtitleTrack == nil)
    }

    @Test(".ready seeds the engine's default-selected audio/subtitle so the menu shows a checkmark")
    func readySeedsDefaultSelection() async throws {
        let reporting = StubPlaybackReporting()
        let engine = FakePlaybackEngine(id: .avKit, capabilities: .avKit)
        let vm = makeVM(reporting: reporting, engine: engine, resolved: PlayerFixtures.resolved(), capturedItem: { _ in })
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
        try await Task.sleep(for: .milliseconds(50))

        #expect(vm.selectedAudioTrack?.id == .avKitOption(1))     // reflects engine default, not just first
        #expect(vm.selectedSubtitleTrack == nil)      // nil subtitle id == "Off"
    }

    @Test("transcode: menus come from MediaStreams; selecting audio re-resolves at position with that index")
    func transcodeAudioSwitch() async throws {
        let reporting = StubPlaybackReporting()
        let engine = FakePlaybackEngine(id: .avKit, capabilities: .avKit)
        let probe = FakeCapabilityProbe(hdr: .none, audioOutput: .stereo)
        let builder = DeviceProfileBuilder(probe: probe)
        let resolved = PlayerFixtures.resolvedMultiTrackTranscode()

        nonisolated(unsafe) var resolveCalls: [(audio: Int?, sub: Int?, start: CMTime?)] = []
        let vm = PlayerViewModel(
            deviceProfileBuilder: builder,
            playbackInfo: reporting,
            resolve: { _, _, start, audioIdx, subIdx in
                resolveCalls.append((audioIdx, subIdx, start))
                return resolved
            },
            engineFactory: { _ in engine },
            audioSession: NoopAudioSession()
        )

        await vm.start(item: PlayerFixtures.movieDetail())

        // Menus reflect the server's FULL track list, not the one-rendition manifest.
        #expect(vm.availableAudioTracks.count == 3)
        #expect(vm.availableSubtitleTracks.count == 1)                  // PGS (image) sub filtered out — no burn-in this phase
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
        engine.push(.playing(
            position: CMTime(seconds: 100, preferredTimescale: 600),
            duration: CMTime(seconds: 7200, preferredTimescale: 600),
            buffered: nil
        ))
        try await Task.sleep(for: .milliseconds(50))

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

    @Test("transcode resumes by client seek: the asset carries the offset and a switch resumes at the live position (no origin double-count)")
    func transcodeResumeSeeksClientSide() async throws {
        let reporting = StubPlaybackReporting()
        let engine = FakePlaybackEngine(id: .avKit, capabilities: .avKit)
        let probe = FakeCapabilityProbe(hdr: .none, audioOutput: .stereo)
        let builder = DeviceProfileBuilder(probe: probe)
        // Resolve resuming at 600s. Jellyfin's transcode is a full-timeline playlist
        // that ignores StartTimeTicks for the offset, so the engine must SEEK there.
        let resolved = PlayerFixtures.resolvedMultiTrackTranscode(
            startTime: CMTime(seconds: 600, preferredTimescale: 600)
        )

        nonisolated(unsafe) var resolveStarts: [CMTime?] = []
        let vm = PlayerViewModel(
            deviceProfileBuilder: builder,
            playbackInfo: reporting,
            resolve: { _, _, start, _, _ in resolveStarts.append(start); return resolved },
            engineFactory: { _ in engine },
            audioSession: NoopAudioSession()
        )
        await vm.start(item: PlayerFixtures.movieDetail())

        // The transcode asset must carry the resume offset so the engine seeks to it
        // — was nil, so every transcode (incl. resume) restarted at 0:00.
        #expect(CMTimeGetSeconds(engine.loadedAssets.first?.startTime ?? .invalid) == 600)

        // currentPosition is absolute media time (the engine seeked); a switch must
        // resume THERE — not origin(600) + position(900) = 1500.
        engine.push(.playing(
            position: CMTime(seconds: 900, preferredTimescale: 600),
            duration: CMTime(seconds: 7200, preferredTimescale: 600),
            buffered: nil
        ))
        try await Task.sleep(for: .milliseconds(50))

        let audio4 = try #require(vm.availableAudioTracks.first { $0.id == .jellyfinStream(4) })
        await vm.selectAudioTrack(audio4)

        // `.last` of [CMTime?] is doubly-optional — flatten before comparing.
        let switchStart = try #require(resolveStarts.last ?? nil)
        #expect(CMTimeGetSeconds(switchStart) == 900)
    }

    @Test("transcode audio switch reuses the engine instance — the video surface isn't torn down to black")
    func transcodeSwitchReusesEngine() async throws {
        let reporting = StubPlaybackReporting()
        let probe = FakeCapabilityProbe(hdr: .none, audioOutput: .stereo)
        let builder = DeviceProfileBuilder(probe: probe)
        let resolved = PlayerFixtures.resolvedMultiTrackTranscode()

        // A factory that builds a DISTINCT engine per call, so a re-creation would
        // bump the count and break identity — the assertions below prove reuse.
        nonisolated(unsafe) var createdEngines: [FakePlaybackEngine] = []
        let vm = PlayerViewModel(
            deviceProfileBuilder: builder,
            playbackInfo: reporting,
            resolve: { _, _, _, _, _ in resolved },
            engineFactory: { _ in
                let engine = FakePlaybackEngine(id: .avKit, capabilities: .avKit)
                createdEngines.append(engine)
                return engine
            },
            audioSession: NoopAudioSession()
        )
        await vm.start(item: PlayerFixtures.movieDetail())
        let engineAfterStart = try #require(vm.engine as? FakePlaybackEngine)
        #expect(createdEngines.count == 1)

        createdEngines[0].push(.playing(
            position: CMTime(seconds: 100, preferredTimescale: 600),
            duration: CMTime(seconds: 7200, preferredTimescale: 600),
            buffered: nil
        ))
        try await Task.sleep(for: .milliseconds(50))

        // Switch audio → the engine is RELOADED in place, not recreated, so its
        // AVPlayer layer stays mounted (no black teardown between old + new streams).
        let audio4 = try #require(vm.availableAudioTracks.first { $0.id == .jellyfinStream(4) })
        await vm.selectAudioTrack(audio4)

        #expect(createdEngines.count == 1)                                       // factory NOT called again
        #expect((vm.engine as? FakePlaybackEngine) === engineAfterStart)         // same instance, reloaded
        #expect(engineAfterStart.loadedAssets.count == 2)                        // start load + switch reload
        #expect(!engineAfterStart.calls.contains("teardown"))                    // never torn down across the swap
        #expect(engineAfterStart.calls.contains("pause"))                        // frame frozen at selection
    }

    @Test("transcode: subtitle selection is isolated — an explicit sub survives an audio switch; none stays none")
    func transcodeSubtitleIsolation() async throws {
        let reporting = StubPlaybackReporting()
        let engine = FakePlaybackEngine(id: .avKit, capabilities: .avKit)
        let probe = FakeCapabilityProbe(hdr: .none, audioOutput: .stereo)
        let builder = DeviceProfileBuilder(probe: probe)
        // No server default subtitle: this test is about EXPLICIT selection
        // isolation, so nothing may be auto-applied at start.
        let resolved = PlayerFixtures.resolvedMultiTrackTranscode(defaultSubtitleStreamIndex: nil)

        nonisolated(unsafe) var resolveCalls: [(audio: Int?, sub: Int?)] = []
        let vm = PlayerViewModel(
            deviceProfileBuilder: builder,
            playbackInfo: reporting,
            resolve: { _, _, _, audioIdx, subIdx in
                resolveCalls.append((audioIdx, subIdx))
                return resolved
            },
            engineFactory: { _ in engine },
            audioSession: NoopAudioSession()
        )
        await vm.start(item: PlayerFixtures.movieDetail())
        engine.push(.playing(
            position: CMTime(seconds: 50, preferredTimescale: 600),
            duration: CMTime(seconds: 7200, preferredTimescale: 600),
            buffered: nil
        ))
        try await Task.sleep(for: .milliseconds(50))

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

    @Test("transcode: picking a text subtitle fetches + parses a sidecar VTT (no re-resolve); Off clears it")
    func transcodeSidecarSubtitle() async throws {
        let reporting = StubPlaybackReporting()
        let engine = FakePlaybackEngine(id: .avKit, capabilities: .avKit)
        let probe = FakeCapabilityProbe(hdr: .none, audioOutput: .stereo)
        let builder = DeviceProfileBuilder(probe: probe)
        let resolved = PlayerFixtures.resolvedMultiTrackTranscode()
        let vtt = Data("WEBVTT\n\n00:00:01.000 --> 00:00:03.000\nNi hao".utf8)

        nonisolated(unsafe) var resolveCount = 0
        nonisolated(unsafe) var fetchedURLs: [URL] = []
        let vm = PlayerViewModel(
            deviceProfileBuilder: builder,
            playbackInfo: reporting,
            resolve: { _, _, _, _, _ in resolveCount += 1; return resolved },
            engineFactory: { _ in engine },
            audioSession: NoopAudioSession(),
            subtitleFetch: { url in fetchedURLs.append(url); return vtt }
        )
        await vm.start(item: PlayerFixtures.movieDetail())
        let resolvesAfterStart = resolveCount

        // Pick the Chinese text sub → fetch + parse the sidecar; no re-transcode.
        let chinese = try #require(vm.availableSubtitleTracks.first { $0.id == .jellyfinStream(1) })
        await vm.selectSubtitleTrack(chinese)
        try await Task.sleep(for: .milliseconds(50))   // let the fetch Task land

        #expect(resolveCount == resolvesAfterStart)                                   // no re-resolve
        #expect(fetchedURLs.first?.absoluteString.contains("/Subtitles/1/Stream.vtt") == true)
        #expect(vm.activeSubtitleCues.count == 1)
        #expect(vm.activeSubtitleCues.first?.text == "Ni hao")
        #expect(vm.selectedSubtitleTrack?.id == .jellyfinStream(1))

        // Off → cues + selection cleared, still no re-resolve.
        await vm.selectSubtitleTrack(nil)
        #expect(vm.activeSubtitleCues.isEmpty)
        #expect(vm.selectedSubtitleTrack == nil)
        #expect(resolveCount == resolvesAfterStart)
    }

    @Test("isPlaying tracks engine play/pause so the button can resume from pause")
    func isPlayingTracksPauseState() async throws {
        let reporting = StubPlaybackReporting()
        let engine = FakePlaybackEngine(id: .avKit, capabilities: .avKit)
        let resolved = PlayerFixtures.resolved()
        let vm = makeVM(reporting: reporting, engine: engine, resolved: resolved, capturedItem: { _ in })
        await vm.start(item: PlayerFixtures.movieDetail())

        engine.push(.playing(position: CMTime(seconds: 10, preferredTimescale: 1), duration: resolved.runtime!, buffered: nil))
        try await Task.sleep(for: .milliseconds(50))
        #expect(vm.isPlaying == true)

        // The bug this guards: phase stays .playing while paused, so a phase-derived
        // button stayed "pause" forever. isPlaying must flip so resume is reachable.
        engine.push(.paused(position: CMTime(seconds: 10, preferredTimescale: 1), duration: resolved.runtime!, buffered: nil))
        try await Task.sleep(for: .milliseconds(50))
        #expect(vm.isPlaying == false)
        #expect(vm.phase == .playing)   // video surface stays up; only isPlaying flips
    }

    @Test("togglePlayPause flips isPlaying optimistically, before any engine beat")
    func togglePlayPauseIsOptimistic() async throws {
        let reporting = StubPlaybackReporting()
        let engine = FakePlaybackEngine(id: .avKit, capabilities: .avKit)
        let resolved = PlayerFixtures.resolved()
        let vm = makeVM(reporting: reporting, engine: engine, resolved: resolved, capturedItem: { _ in })
        await vm.start(item: PlayerFixtures.movieDetail())
        engine.push(.playing(position: CMTime(seconds: 10, preferredTimescale: 1), duration: resolved.runtime!, buffered: nil))
        try await Task.sleep(for: .milliseconds(50))
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
        let vm = makeVM(reporting: reporting, engine: engine, resolved: resolved, capturedItem: { _ in })
        await vm.start(item: PlayerFixtures.movieDetail())
        engine.push(.playing(position: CMTime(seconds: 10, preferredTimescale: 1), duration: resolved.runtime!, buffered: nil))
        try await Task.sleep(for: .milliseconds(50))
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

    @Test("buffered beat → bufferedFraction; nil beat (VLC) hides the layer; stop() clears it")
    func bufferedFractionTracksBeats() async throws {
        let reporting = StubPlaybackReporting()
        let engine = FakePlaybackEngine(id: .avKit, capabilities: .avKit)
        let resolved = PlayerFixtures.resolved()
        let vm = makeVM(reporting: reporting, engine: engine, resolved: resolved, capturedItem: { _ in })
        await vm.start(item: PlayerFixtures.movieDetail())

        // runtime fixture is the duration; buffer extends to its midpoint.
        let duration = resolved.runtime!
        let half = CMTime(seconds: CMTimeGetSeconds(duration) / 2, preferredTimescale: 600)
        engine.push(.playing(position: CMTime(seconds: 10, preferredTimescale: 1), duration: duration, buffered: half))
        try await Task.sleep(for: .milliseconds(50))
        let fraction = try #require(vm.bufferedFraction)
        #expect(abs(fraction - 0.5) < 0.001)

        // A nil buffered beat (VLC path) must hide the layer, not freeze the last value.
        engine.push(.paused(position: CMTime(seconds: 10, preferredTimescale: 1), duration: duration, buffered: nil))
        try await Task.sleep(for: .milliseconds(50))
        #expect(vm.bufferedFraction == nil)

        await vm.stop()
        #expect(vm.bufferedFraction == nil)
    }

    @Test("mid-stream stall: .buffering beats raise isStalled after the debounce; playing clears it edge-on")
    func stallDebounceLifecycle() async throws {
        let reporting = StubPlaybackReporting()
        let engine = FakePlaybackEngine(id: .avKit, capabilities: .avKit)
        let resolved = PlayerFixtures.resolved()
        let vm = makeVM(reporting: reporting, engine: engine, resolved: resolved, capturedItem: { _ in })
        await vm.start(item: PlayerFixtures.movieDetail())

        engine.push(.playing(position: CMTime(seconds: 10, preferredTimescale: 1), duration: resolved.runtime!, buffered: nil))
        try await Task.sleep(for: .milliseconds(50))

        // A short blip (healthy in-buffer seek) never shows the scrim.
        engine.push(.buffering(position: CMTime(seconds: 10, preferredTimescale: 1), duration: resolved.runtime!, buffered: nil))
        try await Task.sleep(for: .milliseconds(50))
        #expect(vm.isStalled == false)
        engine.push(.playing(position: CMTime(seconds: 11, preferredTimescale: 1), duration: resolved.runtime!, buffered: nil))
        try await Task.sleep(for: .milliseconds(500))
        #expect(vm.isStalled == false)   // debounce was cancelled, not just delayed

        // A real stall crosses the debounce: scrim shows, phase + intent untouched.
        engine.push(.buffering(position: CMTime(seconds: 11, preferredTimescale: 1), duration: resolved.runtime!, buffered: nil))
        try await Task.sleep(for: .milliseconds(600))
        #expect(vm.isStalled == true)
        #expect(vm.showsStallScrim == true)
        #expect(vm.loaderTitle == "Buffering")
        #expect(vm.phase == .playing)
        #expect(vm.isPlaying == true)

        // Recovery clears it immediately.
        engine.push(.playing(position: CMTime(seconds: 12, preferredTimescale: 1), duration: resolved.runtime!, buffered: nil))
        try await Task.sleep(for: .milliseconds(50))
        #expect(vm.isStalled == false)
        #expect(vm.showsStallScrim == false)

        // Paused-seek shape (drag-scrub commits pause → seek → play): the engine
        // surfaces the out-of-buffer fetch as .buffering with a JUMPED position,
        // which stalls immediately (no debounce — the fetch is real by
        // construction); the completion's .paused beat clears it, no .playing
        // required.
        engine.push(.buffering(position: CMTime(seconds: 300, preferredTimescale: 1), duration: resolved.runtime!, buffered: nil))
        try await Task.sleep(for: .milliseconds(50))
        #expect(vm.isStalled == true)
        engine.push(.paused(position: CMTime(seconds: 300, preferredTimescale: 1), duration: resolved.runtime!, buffered: nil))
        try await Task.sleep(for: .milliseconds(50))
        #expect(vm.isStalled == false)
        #expect(vm.isPlaying == false)
    }

    @Test("transcode track switch closes the outgoing session before opening the next")
    func transcodeSwitchClosesOldSession() async throws {
        let reporting = StubPlaybackReporting()
        let engine = FakePlaybackEngine(id: .avKit, capabilities: .avKit)
        let probe = FakeCapabilityProbe(hdr: .none, audioOutput: .stereo)
        let builder = DeviceProfileBuilder(probe: probe)
        let resolved = PlayerFixtures.resolvedMultiTrackTranscode()
        let vm = PlayerViewModel(
            deviceProfileBuilder: builder,
            playbackInfo: reporting,
            resolve: { _, _, _, _, _ in resolved },
            engineFactory: { _ in engine },
            audioSession: NoopAudioSession()
        )
        await vm.start(item: PlayerFixtures.movieDetail())
        engine.push(.playing(
            position: CMTime(seconds: 100, preferredTimescale: 600),
            duration: CMTime(seconds: 7200, preferredTimescale: 600),
            buffered: nil
        ))
        try await Task.sleep(for: .milliseconds(50))

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
        let builder = DeviceProfileBuilder(probe: FakeCapabilityProbe(hdr: .none, audioOutput: .stereo))
        let resolved = PlayerFixtures.resolvedMultiTrackTranscode()
        let vm = PlayerViewModel(
            deviceProfileBuilder: builder,
            playbackInfo: reporting,
            resolve: { _, _, _, _, _ in resolved },
            engineFactory: { _ in engine },
            audioSession: NoopAudioSession(),
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
        let directVM = PlayerViewModel(
            deviceProfileBuilder: builder,
            playbackInfo: directReporting,
            resolve: { _, _, _, _, _ in PlayerFixtures.resolved() },
            engineFactory: { _ in FakePlaybackEngine(id: .avKit, capabilities: .avKit) },
            audioSession: NoopAudioSession(),
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
        let builder = DeviceProfileBuilder(probe: FakeCapabilityProbe(hdr: .none, audioOutput: .stereo))
        let resolved = PlayerFixtures.resolvedMultiTrackTranscode()
        let vm = PlayerViewModel(
            deviceProfileBuilder: builder,
            playbackInfo: reporting,
            resolve: { _, _, _, _, _ in resolved },
            engineFactory: { _ in engine },
            audioSession: NoopAudioSession(),
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
        let vm = makeVM(reporting: reporting, engine: engine, resolved: PlayerFixtures.resolved(), capturedItem: { _ in })
        await vm.start(item: PlayerFixtures.movieDetail())

        let track = AudioTrack(id: .avKitOption(1), displayName: "English", languageCode: "en")
        engine.push(.ready(duration: CMTime(seconds: 7200, preferredTimescale: 600), tracks: TrackInventory(audio: [track], subtitles: [])))
        try await Task.sleep(for: .milliseconds(50))

        await vm.selectAudioTrack(track)
        #expect(vm.selectedAudioTrack?.id == .avKitOption(1))
        #expect(engine.selectedAudioTrackID == .avKitOption(1))
    }

    @Test("selectSubtitleTrack nil deselects and forwards nil to engine")
    func subtitleTrackDeselect() async throws {
        let reporting = StubPlaybackReporting()
        let engine = FakePlaybackEngine(id: .avKit, capabilities: .avKit)
        let vm = makeVM(reporting: reporting, engine: engine, resolved: PlayerFixtures.resolved(), capturedItem: { _ in })
        await vm.start(item: PlayerFixtures.movieDetail())

        let sub = SubtitleTrack(id: .avKitOption(1), displayName: "English", languageCode: "en", isForced: false)
        engine.push(.ready(duration: CMTime(seconds: 7200, preferredTimescale: 600), tracks: TrackInventory(audio: [], subtitles: [sub])))
        try await Task.sleep(for: .milliseconds(50))

        await vm.selectSubtitleTrack(sub)
        #expect(vm.selectedSubtitleTrack?.id == .avKitOption(1))

        await vm.selectSubtitleTrack(nil)
        #expect(vm.selectedSubtitleTrack == nil)
        #expect(engine.selectedSubtitleTrackID == nil)
    }

    @Test("VP9/WebM direct-play routes to .vlcKit engine and loads the asset")
    func vp9WebMSelectsVLC() async {
        let reporting = StubPlaybackReporting()
        let vlcEngine = FakePlaybackEngine(id: .vlcKit, capabilities: .vlcKit)
        let vm = makeVM(reporting: reporting, engine: vlcEngine, resolved: PlayerFixtures.resolvedVP9WebM(), capturedItem: { _ in })
        await vm.start(item: PlayerFixtures.movieDetail())

        #expect(vlcEngine.loadedAssets.first != nil)
        #expect(vlcEngine.loadedAssets.first?.hints.container == .webm)
        #expect(vlcEngine.loadedAssets.first?.hints.videoCodec == .vp9)
        #expect(vlcEngine.calls.contains("play"))
        #expect(vm.phase != .failed(.playback(.unsupportedFormat)))
    }

    @Test(".vlcKit engine tracks populate on .ready state")
    func vlcEngineTrackStatePopulates() async throws {
        let reporting = StubPlaybackReporting()
        let vlcEngine = FakePlaybackEngine(id: .vlcKit, capabilities: .vlcKit)
        let vm = makeVM(reporting: reporting, engine: vlcEngine, resolved: PlayerFixtures.resolvedVP9WebM(), capturedItem: { _ in })
        await vm.start(item: PlayerFixtures.movieDetail())

        let inventory = TrackInventory(
            audio: [AudioTrack(id: .vlc("vlc-a1"), displayName: "Deutsch", languageCode: "de")],
            subtitles: [SubtitleTrack(id: .vlc("vlc-s1"), displayName: "ASS Sub", languageCode: "en", isForced: false)]
        )
        vlcEngine.push(.ready(duration: CMTime(seconds: 3600, preferredTimescale: 600), tracks: inventory))
        try await Task.sleep(for: .milliseconds(50))

        #expect(vm.availableAudioTracks.count == 1)
        #expect(vm.availableAudioTracks[0].id == .vlc("vlc-a1"))
        #expect(vm.availableSubtitleTracks.count == 1)
    }

    @Test("VC-1 MKV direct-play calls engineFactory with .vlcKit (5d routing contract)")
    func vc1MKVRoutesToVLCKitFactory() async {
        let reporting = StubPlaybackReporting()
        let fakeEngine = FakePlaybackEngine(id: .vlcKit, capabilities: .vlcKit)
        var capturedEngineID: PlaybackEngineID?
        let probe = FakeCapabilityProbe(hdr: .none, audioOutput: .stereo)
        let builder = DeviceProfileBuilder(probe: probe)
        let vm = PlayerViewModel(
            deviceProfileBuilder: builder,
            playbackInfo: reporting,
            resolve: { _, _, _, _, _ in PlayerFixtures.resolvedVLCDirectPlayMKV() },
            engineFactory: { id in capturedEngineID = id; return fakeEngine },
            audioSession: NoopAudioSession()
        )
        await vm.start(item: PlayerFixtures.movieDetail())
        #expect(capturedEngineID == .vlcKit, "Expected engineFactory called with .vlcKit, got \(String(describing: capturedEngineID))")
        #expect(fakeEngine.loadedAssets.first != nil)
        #expect(fakeEngine.loadedAssets.first?.hints.container == .mkv)
        #expect(fakeEngine.loadedAssets.first?.hints.videoCodec == .vc1)
    }

    @Test("isPiPAvailable mirrors engine.capabilities.supportsPiP")
    func pipAvailabilityMirrorsCapabilities() async {
        let reporting = StubPlaybackReporting()
        let engine = FakePlaybackEngine(id: .avKit, capabilities: .avKit)  // supportsPiP == true
        let vm = makeVM(reporting: reporting, engine: engine, resolved: PlayerFixtures.resolved(), capturedItem: { _ in })
        await vm.start(item: PlayerFixtures.movieDetailNamed("Fixture Movie"))
        #expect(vm.isPiPAvailable == true)
    }

    @Test("startPiP/stopPiP are safe no-ops; isPiPAvailable true when engine supports PiP")
    func pipActionsAreSafeWhenSupported() async {
        let reporting = StubPlaybackReporting()
        let engine = FakePlaybackEngine(id: .avKit, capabilities: .avKit)  // supportsPiP == true
        let vm = makeVM(reporting: reporting, engine: engine, resolved: PlayerFixtures.resolved(), capturedItem: { _ in })
        await vm.start(item: PlayerFixtures.movieDetailNamed("Fixture Movie"))
        #expect(vm.isPiPAvailable == true)
        vm.startPiP()   // no action mounted in tests → safe no-op
        vm.stopPiP()
    }

    @Test("isVideoAirPlayAvailable mirrors engine.capabilities.supportsVideoAirPlay")
    func airPlayAvailabilityMirrorsCapabilities() async {
        let reporting = StubPlaybackReporting()
        let engine = FakePlaybackEngine(id: .avKit, capabilities: .avKit)  // supportsVideoAirPlay == true
        let vm = makeVM(reporting: reporting, engine: engine, resolved: PlayerFixtures.resolved(), capturedItem: { _ in })
        await vm.start(item: PlayerFixtures.movieDetailNamed("Fixture Movie"))
        #expect(vm.isVideoAirPlayAvailable == true)
    }

    @Test("natural end followed by dismissal reports stopped exactly once")
    func endThenDismissReportsStoppedOnce() async throws {
        let reporting = StubPlaybackReporting()
        let engine = FakePlaybackEngine(id: .avKit, capabilities: .avKit)
        let resolved = PlayerFixtures.resolved()

        let vm = makeVM(reporting: reporting, engine: engine, resolved: resolved, capturedItem: { _ in })
        await vm.start(item: PlayerFixtures.movieDetail())
        engine.push(.playing(position: CMTime(seconds: 40, preferredTimescale: 1), duration: resolved.runtime!, buffered: nil))
        engine.push(.ended)
        try await Task.sleep(for: .milliseconds(50))

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
        let probe = FakeCapabilityProbe(hdr: .none, audioOutput: .stereo)
        let builder = DeviceProfileBuilder(probe: probe)
        let resolved = PlayerFixtures.resolvedMultiTrackTranscode()

        nonisolated(unsafe) var callCount = 0
        let vm = PlayerViewModel(
            deviceProfileBuilder: builder,
            playbackInfo: reporting,
            resolve: { _, _, _, _, _ in
                callCount += 1
                if callCount >= 2 { throw AppError.playback(.resourceUnavailable) }  // the switch re-resolve fails
                return resolved
            },
            engineFactory: { _ in engine },
            audioSession: NoopAudioSession()
        )
        await vm.start(item: PlayerFixtures.movieDetail())
        engine.push(.playing(
            position: CMTime(seconds: 100, preferredTimescale: 600),
            duration: CMTime(seconds: 7200, preferredTimescale: 600),
            buffered: nil
        ))
        try await Task.sleep(for: .milliseconds(50))

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
        let probe = FakeCapabilityProbe(hdr: .none, audioOutput: .stereo)
        let builder = DeviceProfileBuilder(probe: probe)
        let resolved = PlayerFixtures.resolvedMultiTrackTranscode()

        nonisolated(unsafe) var callCount = 0
        let vm = PlayerViewModel(
            deviceProfileBuilder: builder,
            playbackInfo: reporting,
            resolve: { _, _, _, _, _ in
                callCount += 1
                if callCount == 2 { throw AppError.playback(.resourceUnavailable) }  // the switch re-resolve fails
                return resolved
            },
            engineFactory: { _ in engine },
            audioSession: NoopAudioSession()
        )
        await vm.start(item: PlayerFixtures.movieDetail())
        engine.push(.playing(
            position: CMTime(seconds: 100, preferredTimescale: 600),
            duration: CMTime(seconds: 7200, preferredTimescale: 600),
            buffered: nil
        ))
        try await Task.sleep(for: .milliseconds(50))

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
        let probe = FakeCapabilityProbe(hdr: .none, audioOutput: .stereo)
        let builder = DeviceProfileBuilder(probe: probe)
        let resolved = PlayerFixtures.resolvedMultiTrackTranscode()

        // The switch's re-resolve is where exit can race in: beginExit() lands while
        // resolve is suspended, then resolve throws a REAL error — which skips every
        // checkStillActive (those only catch CancellationError paths).
        nonisolated(unsafe) var callCount = 0
        nonisolated(unsafe) var triggerExit: (@MainActor () -> Void)? = nil
        let vm = PlayerViewModel(
            deviceProfileBuilder: builder,
            playbackInfo: reporting,
            resolve: { _, _, _, _, _ in
                callCount += 1
                if callCount == 2 {
                    await MainActor.run { triggerExit?() }
                    throw AppError.playback(.resourceUnavailable)
                }
                return resolved
            },
            engineFactory: { _ in engine },
            audioSession: NoopAudioSession()
        )
        triggerExit = { vm.beginExit() }
        await vm.start(item: PlayerFixtures.movieDetail())
        engine.push(.playing(
            position: CMTime(seconds: 100, preferredTimescale: 600),
            duration: CMTime(seconds: 7200, preferredTimescale: 600),
            buffered: nil
        ))
        try await Task.sleep(for: .milliseconds(50))

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
        let probe = FakeCapabilityProbe(hdr: .none, audioOutput: .stereo)
        let builder = DeviceProfileBuilder(probe: probe)
        let resolved = PlayerFixtures.resolvedMultiTrackTranscode()

        nonisolated(unsafe) var resolveCalls: [Int?] = []
        let vm = PlayerViewModel(
            deviceProfileBuilder: builder,
            playbackInfo: reporting,
            resolve: { _, _, _, audioIdx, _ in
                resolveCalls.append(audioIdx)
                if resolveCalls.count == 2 { throw AppError.playback(.resourceUnavailable) }  // first switch fails
                return resolved                                                               // retry succeeds
            },
            engineFactory: { _ in engine },
            audioSession: NoopAudioSession()
        )
        await vm.start(item: PlayerFixtures.movieDetail())
        engine.push(.playing(
            position: CMTime(seconds: 100, preferredTimescale: 600),
            duration: CMTime(seconds: 7200, preferredTimescale: 600),
            buffered: nil
        ))
        try await Task.sleep(for: .milliseconds(50))

        let track = try #require(vm.availableAudioTracks.first { $0.id == .jellyfinStream(4) })
        await vm.selectAudioTrack(track)
        #expect(vm.trackSwitchFailure != nil)

        await vm.retryFailedTrackSwitch()

        #expect(vm.trackSwitchFailure == nil)
        #expect(resolveCalls.last == 4)                          // the retry re-resolved the same track
        #expect(vm.selectedAudioTrack?.id == .jellyfinStream(4)) // and the pick stuck this time

        // Phase stays .loading (the scrim) until the reloaded stream's first beat.
        #expect(vm.phase == .loading)
        engine.push(.playing(
            position: CMTime(seconds: 100, preferredTimescale: 600),
            duration: CMTime(seconds: 7200, preferredTimescale: 600),
            buffered: nil
        ))
        try await Task.sleep(for: .milliseconds(50))
        #expect(vm.phase == .playing)
    }

    @Test("stop() clears a pending trackSwitchFailure")
    func stopClearsTrackSwitchFailure() async throws {
        let reporting = StubPlaybackReporting()
        let engine = FakePlaybackEngine(id: .avKit, capabilities: .avKit)
        let probe = FakeCapabilityProbe(hdr: .none, audioOutput: .stereo)
        let builder = DeviceProfileBuilder(probe: probe)
        let resolved = PlayerFixtures.resolvedMultiTrackTranscode()

        nonisolated(unsafe) var callCount = 0
        let vm = PlayerViewModel(
            deviceProfileBuilder: builder,
            playbackInfo: reporting,
            resolve: { _, _, _, _, _ in
                callCount += 1
                if callCount >= 2 { throw AppError.playback(.resourceUnavailable) }
                return resolved
            },
            engineFactory: { _ in engine },
            audioSession: NoopAudioSession()
        )
        await vm.start(item: PlayerFixtures.movieDetail())
        engine.push(.playing(
            position: CMTime(seconds: 100, preferredTimescale: 600),
            duration: CMTime(seconds: 7200, preferredTimescale: 600),
            buffered: nil
        ))
        try await Task.sleep(for: .milliseconds(50))

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
        let resolved = PlayerFixtures.resolved()
        let vm = makeVM(reporting: reporting, engine: engine, resolved: resolved, capturedItem: { _ in })
        await vm.start(item: PlayerFixtures.movieDetail())

        engine.push(.playing(position: CMTime(seconds: 10, preferredTimescale: 1), duration: resolved.runtime!, buffered: nil))
        try await Task.sleep(for: .milliseconds(50))
        #expect(vm.isPlaying == true)

        engine.push(.failed(.decodeFailed))
        try await Task.sleep(for: .milliseconds(50))
        #expect(vm.isPlaying == false)
        #expect(vm.phase == .failed(.playback(.decodeFailed)))
    }

    @Test("start(itemID:) fetches the detail first, then plays it")
    func startByItemIDFetchesThenPlays() async {
        let reporting = StubPlaybackReporting()
        let engine = FakePlaybackEngine(id: .avKit, capabilities: .avKit)
        let probe = FakeCapabilityProbe(hdr: .none, audioOutput: .stereo)
        let builder = DeviceProfileBuilder(probe: probe)
        nonisolated(unsafe) var fetchedID: ItemID?
        let vm = PlayerViewModel(
            deviceProfileBuilder: builder,
            playbackInfo: reporting,
            resolve: { _, _, _, _, _ in PlayerFixtures.resolved() },
            engineFactory: { _ in engine },
            audioSession: NoopAudioSession(),
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
        let probe = FakeCapabilityProbe(hdr: .none, audioOutput: .stereo)
        let builder = DeviceProfileBuilder(probe: probe)
        nonisolated(unsafe) var didResolve = false
        let vm = PlayerViewModel(
            deviceProfileBuilder: builder,
            playbackInfo: reporting,
            resolve: { _, _, _, _, _ in didResolve = true; return PlayerFixtures.resolved() },
            engineFactory: { _ in engine },
            audioSession: NoopAudioSession(),
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
        let probe = FakeCapabilityProbe(hdr: .none, audioOutput: .stereo)
        let builder = DeviceProfileBuilder(probe: probe)

        // A resolve that parks until the test releases it — the exit lands mid-resolve,
        // exactly like dismissing the player while the PlaybackInfo call is in flight.
        let (gate, gateContinuation) = AsyncStream<Void>.makeStream()
        nonisolated(unsafe) var engineBuilt = false
        let vm = PlayerViewModel(
            deviceProfileBuilder: builder,
            playbackInfo: reporting,
            resolve: { _, _, _, _, _ in
                for await _ in gate { break }
                return PlayerFixtures.resolved()
            },
            engineFactory: { _ in engineBuilt = true; return engine },
            audioSession: NoopAudioSession()
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
        let vm = makeVM(reporting: reporting, engine: engine, resolved: resolved, capturedItem: { _ in })
        await vm.start(item: PlayerFixtures.movieDetail())
        engine.push(.playing(position: CMTime(seconds: 30, preferredTimescale: 1), duration: resolved.runtime!, buffered: nil))
        try await Task.sleep(for: .milliseconds(50))

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
        let probe = FakeCapabilityProbe(hdr: .none, audioOutput: .stereo)
        let builder = DeviceProfileBuilder(probe: probe)

        nonisolated(unsafe) var resolveCalls = 0
        let vm = PlayerViewModel(
            deviceProfileBuilder: builder,
            playbackInfo: reporting,
            resolve: { _, _, _, _, _ in
                resolveCalls += 1
                if resolveCalls == 1 { throw AppError.playback(.resourceUnavailable) }
                return PlayerFixtures.resolved()
            },
            engineFactory: { _ in engine },
            audioSession: NoopAudioSession()
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

    /// All 5 tests that read/write MPNowPlayingInfoCenter.default() are grouped
    /// here with `.serialized` to prevent concurrent async tests from clobbering
    /// each other's nowPlayingInfo state.
    @Suite("NowPlaying", .serialized)
    @MainActor
    struct NowPlayingTests {
        private func makeVM(
            reporting: StubPlaybackReporting,
            engine: FakePlaybackEngine,
            resolved: ResolvedPlayback,
            audioSession: any AudioSessionControlling = NoopAudioSession(),
            capturedItem: @escaping @Sendable (ItemID) -> Void
        ) -> PlayerViewModel {
            let probe = FakeCapabilityProbe(hdr: .none, audioOutput: .stereo)
            let builder = DeviceProfileBuilder(probe: probe)
            return PlayerViewModel(
                deviceProfileBuilder: builder,
                playbackInfo: reporting,
                resolve: { id, _, _, _, _ in
                    capturedItem(id)
                    return resolved
                },
                engineFactory: { _ in engine },
                audioSession: audioSession
            )
        }

        @Test("PlayerViewModel populates MPNowPlayingInfoCenter on .playing")
        func vmPopulatesNowPlayingOnPlaying() async throws {
            let reporting = StubPlaybackReporting()
            let engine = FakePlaybackEngine(id: .avKit, capabilities: .avKit)
            let resolved = PlayerFixtures.resolved()
            let vm = makeVM(reporting: reporting, engine: engine, resolved: resolved, capturedItem: { _ in })
            await vm.start(item: PlayerFixtures.movieDetailNamed("Fixture Movie"))
            engine.push(.playing(position: CMTime(seconds: 30, preferredTimescale: 1), duration: resolved.runtime!, buffered: nil))
            try await Task.sleep(for: .milliseconds(50))
            let info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
            #expect((info[MPMediaItemPropertyTitle] as? String) == "Fixture Movie")
            #expect(((info[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double) ?? 0.0) > 0.0)
            #expect((info[MPNowPlayingInfoPropertyPlaybackRate] as? Double) == 1.0)
            await vm.stop()
        }

        @Test("PlayerViewModel sets rate 0 in MPNowPlayingInfoCenter on .paused")
        func vmSetsNowPlayingRateZeroOnPaused() async throws {
            let reporting = StubPlaybackReporting()
            let engine = FakePlaybackEngine(id: .avKit, capabilities: .avKit)
            let resolved = PlayerFixtures.resolved()
            let vm = makeVM(reporting: reporting, engine: engine, resolved: resolved, capturedItem: { _ in })
            await vm.start(item: PlayerFixtures.movieDetailNamed("Fixture Movie"))
            engine.push(.playing(position: CMTime(seconds: 10, preferredTimescale: 1), duration: resolved.runtime!, buffered: nil))
            engine.push(.paused(position: CMTime(seconds: 10, preferredTimescale: 1), duration: resolved.runtime!, buffered: nil))
            try await Task.sleep(for: .milliseconds(50))
            let info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
            #expect((info[MPNowPlayingInfoPropertyPlaybackRate] as? Double) == 0.0)
            await vm.stop()
        }

        @Test("PlayerViewModel clears MPNowPlayingInfoCenter on stop()")
        func vmClearsNowPlayingOnStop() async throws {
            let reporting = StubPlaybackReporting()
            let engine = FakePlaybackEngine(id: .avKit, capabilities: .avKit)
            let resolved = PlayerFixtures.resolved()
            let vm = makeVM(reporting: reporting, engine: engine, resolved: resolved, capturedItem: { _ in })
            await vm.start(item: PlayerFixtures.movieDetailNamed("Fixture Movie"))
            engine.push(.playing(position: CMTime(seconds: 10, preferredTimescale: 1), duration: resolved.runtime!, buffered: nil))
            try await Task.sleep(for: .milliseconds(50))
            await vm.stop()
            #expect(MPNowPlayingInfoCenter.default().nowPlayingInfo == nil)
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
}
