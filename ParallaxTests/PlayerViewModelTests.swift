import Foundation
import CoreMedia
import Testing
@testable import Parallax
@testable import ParallaxPlayback
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
        capturedItem: @escaping @Sendable (ItemID) -> Void
    ) -> PlayerViewModel {
        let probe = StubCapabilityProbe(hdr: .none, audio: .stereo)
        let builder = DeviceProfileBuilder(probe: probe)
        return PlayerViewModel(
            deviceProfileBuilder: builder,
            playbackInfo: reporting,
            resolve: { id, _, _ in
                capturedItem(id)
                return resolved
            },
            engineFactory: { _ in engine },
            audioSession: NoopAudioSession()
        )
    }

    @Test("resolves, selects .avKit, loads + plays, maps states, emits beats in order")
    func happyPath() async throws {
        let reporting = StubPlaybackReporting()
        let engine = FakePlaybackEngine()
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
        #expect(engine.loadedAsset != nil)
        #expect(engine.loadedAsset?.hints.container == .mp4)
        #expect(engine.didPlay)

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

    @Test("teardown reports stopped and finishes the engine")
    func teardownReportsStopped() async throws {
        let reporting = StubPlaybackReporting()
        let engine = FakePlaybackEngine()
        let resolved = PlayerFixtures.resolved()

        let vm = makeVM(reporting: reporting, engine: engine, resolved: resolved, capturedItem: { _ in })
        await vm.start(item: PlayerFixtures.movieDetail())
        engine.push(.playing(position: CMTime(seconds: 30, preferredTimescale: 1), duration: resolved.runtime!))
        try await Task.sleep(for: .milliseconds(50))

        await vm.stop()
        #expect(engine.didTeardown)

        let events = await reporting.events
        #expect(events.contains(.stopped(ticks: 30 * 10_000_000, itemID: "movie-1")))
    }

    @Test("natural end followed by dismissal reports stopped exactly once")
    func endThenDismissReportsStoppedOnce() async throws {
        let reporting = StubPlaybackReporting()
        let engine = FakePlaybackEngine()
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
