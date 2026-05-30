import Testing
import Foundation
import CoreMedia
@testable import ParallaxPlayback
import ParallaxCore

/// Contract tests for SubtitleResolver exercised through a PlayableAsset
/// (no live VLC needed — these gate the resolver contract, not addPlaybackSlave).
@Suite("VLCKitEngine — SubtitleResolver contract")
struct VLCKitEngineSubtitleTests {

    private func makeSub(format: SubtitleFormat, isForced: Bool = false) -> ExternalSubtitle {
        ExternalSubtitle(
            url: URL(string: "https://jf.example.com/Videos/1/Subtitles/0/Stream.\(format)s?api_key=abc")!,
            format: format,
            languageCode: "en",
            isForced: isForced
        )
    }

    private func makeAsset(subtitles: [ExternalSubtitle]) -> PlayableAsset {
        PlayableAsset(
            url: URL(string: "https://jf.example.com/Videos/movie-1/stream.mkv?api_key=abc")!,
            headers: nil,
            hints: PlaybackHints(
                scheme: "https",
                container: .mkv,
                videoCodec: .vc1,
                audioCodec: .aac,
                subtitleFormats: subtitles.map(\.format)
            ),
            startTime: nil,
            externalSubtitles: subtitles
        )
    }

    @Test("SRT external subtitle resolves to vlcSlave for VLC engine")
    func srtSlaveResolvesForVLC() {
        let sub = makeSub(format: .srt)
        let asset = makeAsset(subtitles: [sub])
        let deliveries = SubtitleResolver.resolveAll(
            subtitles: asset.externalSubtitles,
            engine: .vlcKit
        )
        #expect(deliveries.count == 1)
        if case .vlcSlave(let url, let enforce) = deliveries[0] {
            #expect(url == sub.url)
            #expect(enforce == false)
        } else {
            Issue.record("Expected .vlcSlave for SRT, got \(deliveries[0])")
        }
    }

    @Test("ASS external subtitle resolves to vlcSlave for VLC engine")
    func assSlaveResolvesForVLC() {
        let sub = makeSub(format: .ass, isForced: true)
        let asset = makeAsset(subtitles: [sub])
        let deliveries = SubtitleResolver.resolveAll(
            subtitles: asset.externalSubtitles,
            engine: .vlcKit
        )
        #expect(deliveries.count == 1)
        if case .vlcSlave(let url, let enforce) = deliveries[0] {
            #expect(url == sub.url)
            #expect(enforce == true)
        } else {
            Issue.record("Expected .vlcSlave for ASS, got \(deliveries[0])")
        }
    }

    @Test("Empty external subtitles produces empty deliveries")
    func emptySubtitlesProducesEmptyDeliveries() {
        let asset = makeAsset(subtitles: [])
        let deliveries = SubtitleResolver.resolveAll(
            subtitles: asset.externalSubtitles,
            engine: .vlcKit
        )
        #expect(deliveries.isEmpty)
    }

    @Test("ASS external subtitle is unsupported on AVKit engine")
    func assUnsupportedOnAVKit() {
        let sub = makeSub(format: .ass)
        let asset = makeAsset(subtitles: [sub])
        let deliveries = SubtitleResolver.resolveAll(
            subtitles: asset.externalSubtitles,
            engine: .avKit
        )
        #expect(deliveries.count == 1)
        if case .unsupported = deliveries[0] {
            // correct
        } else {
            Issue.record("Expected .unsupported for ASS on AVKit, got \(deliveries[0])")
        }
    }
}
