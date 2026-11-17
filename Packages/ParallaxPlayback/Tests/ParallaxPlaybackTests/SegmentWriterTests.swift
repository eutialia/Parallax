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
            stream: stream,
            delivery: .copy(
                codec: try #require(stream.parameters.playlistCodec), supplementalCodec: nil,
                decodeLead: track.decodeLead),
            clock: track.clock)
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

    @Test("a segment written one sample per fragment reads back as the same segment written as one fragment",
          arguments: [
              "anamorphic", "audio-ends-early", "audio-ends-two-segments-early", "av1", "dolby-vision-8-1",
              "dolby-vision-8-2", "dolby-vision-8-4", "eac3", "eac3-three-blocks", "flac", "four-audio-tracks", "frame-numbers",
              "frame-numbers-hevc", "h264-ffmpeg", "h264-high10", "h264-mkvmerge", "hdr-hlg", "hdr-pq",
              "he-aac", "he-aac-v2", "late-start", "long-span", "opus",
          ])
    func fragmentsAddUpToTheWholeSegment(name: String) async throws {
        let demuxer = try await BridgeFixture.demuxer(name)
        let plan = try await BridgePlan(reading: demuxer, support: BridgeFixture.everyDecoder, showsHDR: true)
        let everySample = FragmentLimits(bytes: 1, duration: .seconds(Int64.max))

        for track in [plan.video] + plan.audio {
            let rendition = track.rendition
            for (index, segment) in track.segments.enumerated() {
                let packets = try await demuxer.packets(
                    rendition.stream.index, from: segment.entries.lowerBound, to: segment.entries.upperBound,
                    clock: rendition.clock)
                let end = rendition.stream.kind == .video ? nil : segment.end
                let whole = try SegmentWriter.mediaSegment(for: rendition, packets: packets, lastingUntil: end, limits: .whole)
                let split = try SegmentWriter.mediaSegment(for: rendition, packets: packets, lastingUntil: end, limits: everySample)
                #expect(
                    try readBackSamples(of: track.initSegment + split, pathExtension: "mp4")
                        == readBackSamples(of: track.initSegment + whole, pathExtension: "mp4"),
                    "\(rendition.codec) segment \(index)")
            }
        }
    }

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

        #expect(throws: SegmentWriter.Failure.reorderedTooFar) {
            _ = try SegmentWriter.mediaSegment(for: plan.video.rendition, packets: reordered)
        }
    }
}
