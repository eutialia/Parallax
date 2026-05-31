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
            resolve: { id, _, _ in
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
        engine.push(.playing(position: CMTime(seconds: 10, preferredTimescale: 1), duration: resolved.runtime!))
        engine.push(.playing(position: CMTime(seconds: 20, preferredTimescale: 1), duration: resolved.runtime!))
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
        engine.push(.playing(position: CMTime(seconds: 30, preferredTimescale: 1), duration: resolved.runtime!))
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
                AudioTrack(id: "a1", displayName: "English", languageCode: "en"),
                AudioTrack(id: "a2", displayName: "French", languageCode: "fr"),
            ],
            subtitles: [
                SubtitleTrack(id: "s1", displayName: "English SDH", languageCode: "en", isForced: false),
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
                AudioTrack(id: "0", displayName: "Audio 1", languageCode: nil),
                AudioTrack(id: "1", displayName: "English", languageCode: "en"),
            ],
            subtitles: [
                SubtitleTrack(id: "0", displayName: "English", languageCode: "en", isForced: false),
            ],
            selectedAudioID: "1",
            selectedSubtitleID: nil
        )
        engine.push(.ready(duration: CMTime(seconds: 3600, preferredTimescale: 600), tracks: inventory))
        try await Task.sleep(for: .milliseconds(50))

        #expect(vm.selectedAudioTrack?.id == "1")     // reflects engine default, not just first
        #expect(vm.selectedSubtitleTrack == nil)      // nil subtitle id == "Off"
    }

    @Test("selectAudioTrack forwards to the engine and updates selectedAudioTrack")
    func audioTrackSelectionForwardsToEngine() async throws {
        let reporting = StubPlaybackReporting()
        let engine = FakePlaybackEngine(id: .avKit, capabilities: .avKit)
        let vm = makeVM(reporting: reporting, engine: engine, resolved: PlayerFixtures.resolved(), capturedItem: { _ in })
        await vm.start(item: PlayerFixtures.movieDetail())

        let track = AudioTrack(id: "a1", displayName: "English", languageCode: "en")
        engine.push(.ready(duration: CMTime(seconds: 7200, preferredTimescale: 600), tracks: TrackInventory(audio: [track], subtitles: [])))
        try await Task.sleep(for: .milliseconds(50))

        await vm.selectAudioTrack(track)
        #expect(vm.selectedAudioTrack?.id == "a1")
        #expect(engine.selectedAudioTrackID == "a1")
    }

    @Test("selectSubtitleTrack nil deselects and forwards nil to engine")
    func subtitleTrackDeselect() async throws {
        let reporting = StubPlaybackReporting()
        let engine = FakePlaybackEngine(id: .avKit, capabilities: .avKit)
        let vm = makeVM(reporting: reporting, engine: engine, resolved: PlayerFixtures.resolved(), capturedItem: { _ in })
        await vm.start(item: PlayerFixtures.movieDetail())

        let sub = SubtitleTrack(id: "s1", displayName: "English", languageCode: "en", isForced: false)
        engine.push(.ready(duration: CMTime(seconds: 7200, preferredTimescale: 600), tracks: TrackInventory(audio: [], subtitles: [sub])))
        try await Task.sleep(for: .milliseconds(50))

        await vm.selectSubtitleTrack(sub)
        #expect(vm.selectedSubtitleTrack?.id == "s1")

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
            audio: [AudioTrack(id: "vlc-a1", displayName: "Deutsch", languageCode: "de")],
            subtitles: [SubtitleTrack(id: "vlc-s1", displayName: "ASS Sub", languageCode: "en", isForced: false)]
        )
        vlcEngine.push(.ready(duration: CMTime(seconds: 3600, preferredTimescale: 600), tracks: inventory))
        try await Task.sleep(for: .milliseconds(50))

        #expect(vm.availableAudioTracks.count == 1)
        #expect(vm.availableAudioTracks[0].id == "vlc-a1")
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
            resolve: { _, _, _ in PlayerFixtures.resolvedVLCDirectPlayMKV() },
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
        engine.push(.playing(position: CMTime(seconds: 40, preferredTimescale: 1), duration: resolved.runtime!))
        engine.push(.ended)
        try await Task.sleep(for: .milliseconds(50))

        // PlayerView.onDisappear always calls stop(); after a natural .ended that
        // already reported stopped, stop() must NOT emit a second stopped beat.
        await vm.stop()

        let events = await reporting.events
        let stoppedCount = events.filter { if case .stopped = $0 { return true } else { return false } }.count
        #expect(stoppedCount == 1)
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
                resolve: { id, _, _ in
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
            engine.push(.playing(position: CMTime(seconds: 30, preferredTimescale: 1), duration: resolved.runtime!))
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
            engine.push(.playing(position: CMTime(seconds: 10, preferredTimescale: 1), duration: resolved.runtime!))
            engine.push(.paused(position: CMTime(seconds: 10, preferredTimescale: 1), duration: resolved.runtime!))
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
            engine.push(.playing(position: CMTime(seconds: 10, preferredTimescale: 1), duration: resolved.runtime!))
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
