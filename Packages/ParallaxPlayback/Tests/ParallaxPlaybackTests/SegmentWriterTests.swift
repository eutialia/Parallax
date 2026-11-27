import Foundation
import Testing
@testable import ParallaxPlayback

/// A stream that reorders its pictures further than it declares, which no encoder a test host
/// has writes.
@Suite("SegmentWriter", .timeLimit(.minutes(1)))
struct SegmentWriterTests {
    @Test("a picture shown earlier than one already given its decode time fails the segment")
    func pictureReorderedPastTheLookaheadFails() async throws {
        let demuxer = try await BridgeFixture.demuxer("h264-mkvmerge")
        let plan = try await BridgePlan(reading: demuxer, support: BridgeFixture.everyDecoder, showsHDR: true)
        let segment = plan.video.segments[1]
        let packets = try await demuxer.packets(0, from: segment.entries.lowerBound, to: segment.entries.upperBound)
        let earliest = try #require(packets.indices.min { packets[$0].presentationTime! < packets[$1].presentationTime! })
        // The segment's earliest picture moved behind every other: by then decode times past
        // it are given out.
        let reordered = packets.enumerated().filter { $0.offset != earliest }.map(\.element) + [packets[earliest]]

        let writer = try FragmentWriter(plan.video.rendition, limits: .standard)

        #expect(throws: SegmentWriter.Failure.reorderedTooFar) {
            for packet in reordered { _ = try writer.append(packet) }
            _ = try writer.finish()
        }
    }
}
