import Foundation
import CoreMedia
import Testing
@testable import Parallax
import ParallaxPlayback
import ParallaxPlaybackTestSupport
@testable import ParallaxJellyfin
@testable import ParallaxCore

@Suite("PlayerViewModel integration")
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
}
