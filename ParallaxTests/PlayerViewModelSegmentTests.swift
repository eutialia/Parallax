import Foundation
import CoreMedia
import Testing
@testable import Parallax
import ParallaxPlayback
import ParallaxPlaybackTestSupport
@testable import ParallaxJellyfin
@testable import ParallaxCore

/// Layer 2 of the skip-intro / next-episode feature: the view model's segment
/// detection (Skip Intro / Next Episode prompt), the skip seek, and episode
/// succession (manual prev/next + end-of-video auto-advance). The data layer is
/// covered in ParallaxJellyfin's MediaSegmentTests.
@Suite("PlayerViewModel segments & succession", .serialized)
@MainActor
struct PlayerViewModelSegmentTests {
    private let builder = DeviceProfileBuilder(probe: FakeCapabilityProbe(hdr: .none, audioOutput: .stereo))

    private func playing(_ seconds: Double) -> PlaybackState {
        .playing(
            position: CMTime(seconds: seconds, preferredTimescale: 600),
            duration: CMTime(seconds: 1800, preferredTimescale: 600),
            buffered: nil
        )
    }

    // MARK: Segment detection + skip

    @Test("an intro segment surfaces a Skip prompt; skipActiveSegment seeks to its end")
    func skipIntroSeeksToEnd() async throws {
        let engine = FakePlaybackEngine(id: .avKit, capabilities: .avKit)
        let intro = MediaSegment(id: "intro", kind: .intro, start: .seconds(0), end: .seconds(90))
        let vm = PlayerViewModel(
            deviceProfileBuilder: builder,
            playbackInfo: StubPlaybackReporting(),
            resolve: { id, _, _, _, _ in PlayerFixtures.resolvedEpisode(id: id.rawValue) },
            engineFactory: { _ in engine },
            audioSession: NoopAudioSession(),
            fetchSegments: { _ in [intro] }
        )

        await vm.start(item: PlayerFixtures.episodeDetail(id: "ep-1"))
        try await Task.sleep(for: .milliseconds(50))   // let the segments task land
        engine.push(playing(30))                        // playhead inside the intro
        try await Task.sleep(for: .milliseconds(50))

        #expect(vm.activeSegment?.kind == .intro)
        #expect(vm.segmentPrompt == .skip(intro))

        await vm.skipActiveSegment()
        #expect(engine.calls.contains("seek(90.0)"))
    }

    @Test("the prompt clears once the playhead leaves the segment")
    func promptClearsAfterSegment() async throws {
        let engine = FakePlaybackEngine(id: .avKit, capabilities: .avKit)
        let intro = MediaSegment(id: "intro", kind: .intro, start: .seconds(0), end: .seconds(90))
        let vm = PlayerViewModel(
            deviceProfileBuilder: builder,
            playbackInfo: StubPlaybackReporting(),
            resolve: { id, _, _, _, _ in PlayerFixtures.resolvedEpisode(id: id.rawValue) },
            engineFactory: { _ in engine },
            audioSession: NoopAudioSession(),
            fetchSegments: { _ in [intro] }
        )
        await vm.start(item: PlayerFixtures.episodeDetail(id: "ep-1"))
        try await Task.sleep(for: .milliseconds(50))

        engine.push(playing(30))
        try await Task.sleep(for: .milliseconds(50))
        #expect(vm.segmentPrompt != nil)

        engine.push(playing(120))                       // past the intro's end (exclusive)
        try await Task.sleep(for: .milliseconds(50))
        #expect(vm.segmentPrompt == nil)
        #expect(vm.activeSegment == nil)
    }

    // MARK: Outro → Next Episode gating

    @Test("an outro surfaces Next Episode only when a next episode exists")
    func outroPromptGatesOnNextEpisode() async throws {
        let outro = MediaSegment(id: "outro", kind: .outro, start: .seconds(1700), end: .seconds(1800))

        // With a next episode → Next Episode prompt.
        let engineA = FakePlaybackEngine(id: .avKit, capabilities: .avKit)
        let vmA = PlayerViewModel(
            deviceProfileBuilder: builder,
            playbackInfo: StubPlaybackReporting(),
            resolve: { id, _, _, _, _ in PlayerFixtures.resolvedEpisode(id: id.rawValue) },
            engineFactory: { _ in engineA },
            audioSession: NoopAudioSession(),
            fetchSegments: { _ in [outro] },
            fetchAdjacent: { _, _ in AdjacentEpisodes(previous: nil, next: PlayerFixtures.episode(id: "ep-2", number: 2)) }
        )
        await vmA.start(item: PlayerFixtures.episodeDetail(id: "ep-1"))
        try await Task.sleep(for: .milliseconds(50))
        engineA.push(playing(1750))
        try await Task.sleep(for: .milliseconds(50))
        #expect(vmA.segmentPrompt == .nextEpisode(outro))

        // No next episode (finale) → the outro is active but shows no prompt.
        let engineB = FakePlaybackEngine(id: .avKit, capabilities: .avKit)
        let vmB = PlayerViewModel(
            deviceProfileBuilder: builder,
            playbackInfo: StubPlaybackReporting(),
            resolve: { id, _, _, _, _ in PlayerFixtures.resolvedEpisode(id: id.rawValue) },
            engineFactory: { _ in engineB },
            audioSession: NoopAudioSession(),
            fetchSegments: { _ in [outro] },
            fetchAdjacent: { _, _ in .none }
        )
        await vmB.start(item: PlayerFixtures.episodeDetail(id: "ep-9"))
        try await Task.sleep(for: .milliseconds(50))
        engineB.push(playing(1750))
        try await Task.sleep(for: .milliseconds(50))
        #expect(vmB.activeSegment?.kind == .outro)
        #expect(vmB.segmentPrompt == nil)
    }

    // MARK: Succession (auto-advance + manual)

    /// A VM whose resolve/factory record every resolved id and built engine, with
    /// `fetchDetail` echoing an episode detail for whatever id is requested.
    private func successionVM(
        resolvedIDs: @escaping @Sendable (ItemID) -> Void,
        engines: FakeEngineSink,
        adjacent: @escaping @Sendable (ItemID, ItemID) async -> AdjacentEpisodes
    ) -> PlayerViewModel {
        PlayerViewModel(
            deviceProfileBuilder: builder,
            playbackInfo: StubPlaybackReporting(),
            resolve: { id, _, _, _, _ in resolvedIDs(id); return PlayerFixtures.resolvedEpisode(id: id.rawValue) },
            engineFactory: { _ in engines.make() },
            audioSession: NoopAudioSession(),
            fetchDetail: { id in PlayerFixtures.episodeDetail(id: id.rawValue) },
            fetchAdjacent: adjacent
        )
    }

    @Test("end-of-video auto-advances to the next episode when one exists")
    func endAutoAdvancesToNext() async throws {
        let ids = IDRecorder()
        let engines = FakeEngineSink()
        let vm = successionVM(
            resolvedIDs: { ids.append($0) },
            engines: engines,
            adjacent: { _, episodeID in
                episodeID == ItemID(rawValue: "ep-1")
                    ? AdjacentEpisodes(previous: nil, next: PlayerFixtures.episode(id: "ep-2", number: 2))
                    : .none
            }
        )
        await vm.start(item: PlayerFixtures.episodeDetail(id: "ep-1"))
        try await Task.sleep(for: .milliseconds(50))

        engines.first?.push(playing(1790))
        engines.first?.push(.ended)
        try await Task.sleep(for: .milliseconds(250))   // .ended → task → stop → start(ep-2) → resolve

        #expect(ids.values.contains(ItemID(rawValue: "ep-2")))
        #expect(engines.count == 2)                     // a fresh engine for ep-2
    }

    @Test("end-of-video on a finale (no next) does not auto-advance")
    func endOnFinaleDoesNotAdvance() async throws {
        let ids = IDRecorder()
        let engines = FakeEngineSink()
        let vm = successionVM(resolvedIDs: { ids.append($0) }, engines: engines, adjacent: { _, _ in .none })
        await vm.start(item: PlayerFixtures.episodeDetail(id: "ep-9"))
        try await Task.sleep(for: .milliseconds(50))

        engines.first?.push(playing(1790))
        engines.first?.push(.ended)
        try await Task.sleep(for: .milliseconds(200))

        #expect(ids.values == [ItemID(rawValue: "ep-9")])
        #expect(engines.count == 1)
    }

    @Test("playPreviousEpisode replays the previous neighbor")
    func playPreviousReplaysPrevious() async throws {
        let ids = IDRecorder()
        let engines = FakeEngineSink()
        let vm = successionVM(
            resolvedIDs: { ids.append($0) },
            engines: engines,
            adjacent: { _, episodeID in
                episodeID == ItemID(rawValue: "ep-2")
                    ? AdjacentEpisodes(previous: PlayerFixtures.episode(id: "ep-1", number: 1), next: nil)
                    : .none
            }
        )
        await vm.start(item: PlayerFixtures.episodeDetail(id: "ep-2", number: 2))
        try await Task.sleep(for: .milliseconds(50))

        await vm.playPreviousEpisode()
        try await Task.sleep(for: .milliseconds(150))

        #expect(ids.values.contains(ItemID(rawValue: "ep-1")))
        #expect(engines.count == 2)
    }
}

/// Records the ids passed to a resolve closure, off-actor-safe for the @Sendable
/// closure capture.
private final class IDRecorder: @unchecked Sendable {
    private(set) var values: [ItemID] = []
    func append(_ id: ItemID) { values.append(id) }
}

/// A factory sink that mints a distinct FakePlaybackEngine per call and keeps the
/// list — episode swaps tear the old engine's stream down, so each item needs its
/// own engine (a single shared instance's finished stream would starve the next).
@MainActor
private final class FakeEngineSink {
    private(set) var engines: [FakePlaybackEngine] = []
    var first: FakePlaybackEngine? { engines.first }
    var count: Int { engines.count }
    func make() -> FakePlaybackEngine {
        let engine = FakePlaybackEngine(id: .avKit, capabilities: .avKit)
        engines.append(engine)
        return engine
    }
}
