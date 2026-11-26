import Foundation
import Testing
import ParallaxCore
import ParallaxTestScaling
@testable import ParallaxPlayback

@Suite("BridgePlan", .scaledTimeLimit())
struct BridgePlanTests {

    @Test("the plan describes and places each stream from the start of the first segment as it would from the whole of it",
          arguments: [
              "anamorphic", "audio-ends-early", "audio-ends-two-segments-early", "av1", "dolby-vision-8-1",
              "dolby-vision-8-2", "dolby-vision-8-4", "eac3", "flac", "four-audio-tracks", "frame-numbers",
              "frame-numbers-hevc", "h264-ffmpeg", "h264-high10", "h264-mkvmerge", "hdr-hlg", "hdr-pq",
              "he-aac", "he-aac-v2", "late-start", "long-span", "opus", "deep-pyramid-hevc", "sparse-clusters",
          ])
    func openingReadStandsForTheFirstSegment(name: String) async throws {
        let demuxer = try await BridgeFixture.demuxer(name)
        let plan = try await BridgePlan(reading: demuxer, support: BridgeFixture.everyDecoder, showsHDR: true)
        let first = plan.video.segments[0].entries
        let whole = try await demuxer.packets(from: first.lowerBound, to: first.upperBound)

        for track in [plan.video] + plan.audio {
            let packets = whole.filter { $0.stream == track.rendition.stream.index }
            #expect(try SegmentWriter.initSegment(for: track.rendition, describedBy: packets) == track.initSegment)
            if let grid = track.rendition.clock.grid {
                #expect(grid.anchor == packets.compactMap(\.presentationTime).min())
            }
        }
    }
}
