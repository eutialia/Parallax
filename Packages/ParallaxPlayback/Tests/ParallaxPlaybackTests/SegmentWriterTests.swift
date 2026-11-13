import Foundation
import Testing
import ParallaxCore
import ParallaxTestScaling
@testable import ParallaxPlayback

/// The oracle for the bytes is ffprobe's packet list of the source fixture. The reader of the
/// segments is libavformat's MP4 demuxer, which shares no code with the muxer that wrote them.
@Suite("SegmentWriter", .scaledTimeLimit())
struct SegmentWriterTests {

    /// The fixtures' first audio sample is at -21 ms and the video decodes two frames (83.3 ms)
    /// ahead, so 105 ms keeps every time at or above zero.
    private static let origin: Int64 = 105_000_000

    struct Track: Sendable, CustomStringConvertible {
        let description: String
        let stream: Int
        let clock: MediaClock
        let decodeLead: Int64
        /// The first sample's time on the rendition's timeline, in ticks.
        let first: Int64
        var step: Int64 { clock.grid!.step }

        static let video = Track(
            description: "H.264", stream: 0,
            clock: MediaClock(
                timescale: 120_000, origin: origin,
                grid: .init(anchor: 0, step: 5000, tolerance: 1_000_000)),
            decodeLead: 10_000, first: 12_600)
        static let aac = Track(
            description: "AAC", stream: 1,
            clock: MediaClock(
                timescale: 48_000, origin: origin,
                grid: .init(anchor: -21_000_000, step: 1024, tolerance: .max)),
            decodeLead: 0, first: 4032)
        static let ac3 = Track(
            description: "AC-3", stream: 2,
            clock: MediaClock(
                timescale: 48_000, origin: origin,
                grid: .init(anchor: -5_000_000, step: 1536, tolerance: .max)),
            decodeLead: 0, first: 4800)
    }

    @Test(
        "the init segment and every span's segment, built last span first, read back as the source's samples, evenly spaced",
        arguments: ["h264-ffmpeg", "h264-mkvmerge"], [Track.video, .aac, .ac3])
    func segmentsReadBackAsTheSourceSamples(name: String, track: Track) async throws {
        let demuxer = try await MediaDemuxer.open(
            InMemoryRandomAccessReader(data: BridgeFixture.data(name)))
        let stream = demuxer.streams[track.stream]
        let rendition = Rendition(
            stream: stream, codec: try #require(stream.parameters.playlistCodec), supplementalCodec: nil, clock: track.clock,
            decodeLead: track.decodeLead)
        let count = try await demuxer.keyframes().count

        var segments: [Int: Data] = [:]
        for lower in (0..<count).reversed() {
            let packets = try await demuxer.packets(from: lower, to: lower + 1).filter { $0.stream == track.stream }
            segments[lower] = try SegmentWriter.mediaSegment(for: rendition, packets: packets)
        }
        let first = try await demuxer.packets(from: 0, to: 1).filter { $0.stream == track.stream }
        let file = try SegmentWriter.initSegment(for: rendition, describedBy: first)
            + (0..<count).flatMap { segments[$0] ?? Data() }

        let readBack = try readBackSamples(of: file, pathExtension: "mp4")
        let source = try BridgeFixture.sourcePackets(name, stream: track.stream)

        #expect(readBack.map { BridgeFixture.SourcePacket(md5: $0.md5, isKeyframe: $0.isKeyframe) } == source)
        #expect(readBack.allSatisfy { $0.timescale == track.clock.timescale })
        // Both fixtures hold evenly spaced samples from first to last, so sample n of a stream
        // displays at exactly `first + n * step`, whatever rounding the container stored.
        #expect(readBack.map(\.presentation).sorted() == source.indices.map { track.first + Int64($0) * track.step })
        #expect(zip(readBack, readBack.dropFirst()).allSatisfy { $0.decode < $1.decode })
        #expect(readBack.allSatisfy { $0.decode <= $0.presentation })
    }
}
