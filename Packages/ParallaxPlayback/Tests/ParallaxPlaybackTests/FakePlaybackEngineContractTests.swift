import CoreMedia
import Foundation
import Testing
import ParallaxPlaybackTestSupport
import ParallaxPlayback

/// The double every scenario drives runs the same stream contract the real engines pass.
@Suite("FakePlaybackEngine — PlaybackEngine stream contract", .timeLimit(.minutes(1)))
@MainActor
struct FakePlaybackEngineContractTests {
    private func makeEngine() -> FakePlaybackEngine {
        FakePlaybackEngine()
    }

    @Test("the state stream is pre-seeded with .idle")
    func emitsIdleFirst() async {
        await PlaybackEngineContract.emitsIdleFirst(makeEngine())
    }

    @Test("teardown finishes the state stream so consumers' for-await loops end")
    func teardownFinishesStream() async {
        await PlaybackEngineContract.teardownFinishesStream(makeEngine())
    }

    @Test("a load goes through the same states, a seek lands the same way while playing, load throws the same errors, and subtitle options are numbered the same",
          arguments: PlaybackEngineClause.allCases)
    func matchesTheOtherEngine(clause: PlaybackEngineClause) async throws {
        try await PlaybackEngineContract.holds(clause) { FakeStage() }
    }
}

/// The fake has no media, so its stage publishes what `AVKitEngine` publishes for the same
/// stream: `AVKitStage` serves the real one.
@MainActor
final class FakeStage: PlaybackEngineStage {
    private let fake = FakePlaybackEngine()
    var engine: any PlaybackEngine { fake }
    private static let subtitled = URL(string: "https://example.com/subtitled/master.m3u8")!

    init() { fake.landsSeeks = true }

    func subtitledStream() -> PlayableAsset { .fixture(url: Self.subtitled) }
    func unplayableStream() -> PlayableAsset { .fixture(url: URL(string: "https://example.com/not-a-stream.m3u8")!) }

    func mediaActs(on asset: PlayableAsset) async throws {
        guard asset.url == Self.subtitled else {
            fake.push(.failed(.assetNotPlayable))
            return
        }
        let duration = CMTime(seconds: 8, preferredTimescale: 600)
        fake.push(.ready(duration: duration, tracks: .avKitSubtitles([
            LegibleRendition(displayName: "English", languageCode: "en"),
            LegibleRendition(displayName: "French", languageCode: "fr", isForcedOnly: true),
            LegibleRendition(displayName: "German", languageCode: "de"),
        ])))
        fake.push(.playing(position: .zero, duration: duration, buffered: nil, provenance: .observed))
    }

    func holdLoads() { fake.hold(.load) }
    func releaseLoads() { fake.release(.load) }
    var parkedLoads: Int { fake.parkedCount(.load) }
    func tearDown() async { await fake.teardown() }
}
