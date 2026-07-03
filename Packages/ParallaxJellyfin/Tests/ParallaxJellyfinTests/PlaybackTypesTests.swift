import Foundation
import CoreMedia
import Testing
import ParallaxCore
@testable import ParallaxJellyfin

@Suite("Playback domain types")
struct PlaybackTypesTests {
    @Test("PlaybackMethod has exactly the two methods resolve() can produce")
    func methods() {
        let all: Set<PlaybackMethod> = [.directPlay, .transcode]
        #expect(all.count == 2)
    }

    @Test("ResolvedPlayback stores url, method, codecs, ids, and times")
    func resolvedShape() {
        let url = URL(string: "https://j.example.com/Videos/x/stream.mp4?api_key=tok")!
        let resolved = ResolvedPlayback(
            itemID: "item-1",
            url: url,
            method: .directPlay,
            container: .mp4,
            videoCodec: .h264,
            audioCodec: .aac,
            mediaSourceID: "ms-1",
            playSessionID: "ps-1",
            runtime: CMTime(seconds: 100, preferredTimescale: 1),
            startTime: CMTime(seconds: 5, preferredTimescale: 1)
        )
        #expect(resolved.itemID == "item-1")
        #expect(resolved.url == url)
        #expect(resolved.method == .directPlay)
        #expect(resolved.container == .mp4)
        #expect(resolved.videoCodec == .h264)
        #expect(resolved.audioCodec == .aac)
        #expect(resolved.mediaSourceID == "ms-1")
        #expect(resolved.playSessionID == "ps-1")
        #expect(resolved.startTime == CMTime(seconds: 5, preferredTimescale: 1))
    }

    @Test("ProgressBeat carries position, paused flag, method, and ids")
    func beatShape() {
        let beat = ProgressBeat(
            positionTicks: 50_000_000,
            isPaused: true,
            method: .transcode,
            itemID: "item-1",
            mediaSourceID: "ms-1",
            playSessionID: "ps-1"
        )
        #expect(beat.positionTicks == 50_000_000)
        #expect(beat.isPaused == true)
        #expect(beat.method == .transcode)
        #expect(beat.itemID == "item-1")
        #expect(beat.mediaSourceID == "ms-1")
        #expect(beat.playSessionID == "ps-1")
    }
}
