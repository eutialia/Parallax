import CryptoKit
import Foundation
import Testing
import ParallaxCore
import ParallaxTestScaling
@testable import ParallaxPlayback

/// The oracle is ffprobe's packet list for each fixture, written by
/// `scripts/gen-demux-fixtures.sh`: an independent reading of the same file.
@Suite("MediaDemuxer", .scaledTimeLimit())
struct MediaDemuxerTests {

    private struct Sample: Equatable, CustomStringConvertible {
        let milliseconds: Int64
        let size: Int
        let isKeyframe: Bool
        let md5: String

        var description: String { "\(milliseconds)ms \(size)B\(isKeyframe ? " key" : "")" }

        init(_ packet: DemuxedPacket) {
            milliseconds = packet.presentationTime.map { $0 / 1_000_000 } ?? .min
            size = packet.data.count
            isKeyframe = packet.isKeyframe
            md5 = Insecure.MD5.hash(data: packet.data).map { String(format: "%02x", $0) }.joined()
        }

        init(row: [Any]) throws {
            milliseconds = try #require(row[1] as? Int64 ?? (row[1] as? Int).map(Int64.init))
            size = try #require(row[2] as? Int)
            isKeyframe = try #require(row[3] as? Bool)
            md5 = try #require(row[4] as? String)
        }
    }

    private static func fixture(_ name: String, _ ext: String) throws -> Data {
        let url = try #require(Bundle.module.url(
            forResource: name, withExtension: ext, subdirectory: "Fixtures/demux"))
        return try Data(contentsOf: url)
    }

    /// ffprobe's packets, per stream, in file order.
    private static func expectedSamples(_ name: String) throws -> [Int: [Sample]] {
        let rows = try #require(
            JSONSerialization.jsonObject(with: fixture(name, "packets.json")) as? [[Any]])
        return try rows.reduce(into: [:]) { byStream, row in
            byStream[try #require(row[0] as? Int), default: []].append(try Sample(row: row))
        }
    }

    private static func samples(_ packets: [DemuxedPacket]) -> [Int: [Sample]] {
        packets.reduce(into: [:]) { $0[$1.stream, default: []].append(Sample($1)) }
    }

    /// Each order makes every span follow one it does not continue from.
    enum Order: String, CaseIterable {
        case descending, oddsThenEvens

        func arranged(_ count: Int) -> [Int] {
            switch self {
            case .descending: (0..<count).reversed()
            case .oddsThenEvens: (0..<count).filter { $0 % 2 == 1 } + (0..<count).filter { $0 % 2 == 0 }
            }
        }
    }

    @Test(
        "spans fetched out of order add up to exactly the file's packets",
        arguments: ["h264-ffmpeg", "h264-mkvmerge"], Order.allCases)
    func spansFetchedOutOfOrderAddUpToTheFile(name: String, order: Order) async throws {
        let demuxer = try await MediaDemuxer.open(
            InMemoryRandomAccessReader(data: Self.fixture(name, "mkv")))
        let count = try await demuxer.keyframes().count
        try #require(count > 4)

        var spans: [Int: [DemuxedPacket]] = [:]
        for lower in order.arranged(count) {
            spans[lower] = try await demuxer.packets(from: lower, to: lower + 1)
        }
        let joined = (0..<count).flatMap { spans[$0] ?? [] }

        #expect(Self.samples(joined) == (try Self.expectedSamples(name)))
    }

    @Test("a stream's codec string names its sample entry and profile", arguments: [
        // The fixture's `hvcC` holds profile 1, compatibility flags 60000000, constraint byte
        // 90 and level 30.
        ("frame-numbers-hevc", ["hvc1.1.6.L30.90", "ac-3"]),
        ("he-aac", ["avc1.64000b", "mp4a.40.5"]),
        ("he-aac-v2", ["avc1.64000b", "mp4a.40.29"]),
    ])
    func streamsReportTheirPlaylistCodec(name: String, codecs: [String]) async throws {
        let demuxer = try await BridgeFixture.demuxer(name)
        #expect(demuxer.streams.map(\.parameters.playlistCodec) == codecs)
    }

    @Test("each stream reports what a sample entry and a timeline need")
    func streamsReportCodecAndTiming() async throws {
        let demuxer = try await MediaDemuxer.open(
            InMemoryRandomAccessReader(data: Self.fixture("h264-mkvmerge", "mkv")))
        let streams = demuxer.streams

        #expect(streams.map(\.parameters.codecName) == ["h264", "aac", "ac3"])
        #expect(streams.map(\.parameters.playlistCodec) == ["avc1.640014", "mp4a.40.2", "ac-3"])
        #expect(streams.map(\.parameters.sampleRate) == [0, 48000, 48000])
        #expect(streams.map(\.parameters.samplesPerFrame) == [0, 1024, 1536])
        #expect(streams[0].parameters.pixelSize == (160, 90))
        #expect(streams[0].frameRate == .init(numerator: 24, denominator: 1))
        #expect(streams.map(\.tick) == [1_000_000, 1_000_000, 1_000_000])
        #expect(demuxer.duration == 12_031_000_000)
        #expect(demuxer.fileSize == 930_719)

        let first = try await demuxer.packets(from: 0, to: 1)
        #expect(first.first { $0.stream == 0 }?.duration == 41_000_000)
        #expect(first.first { $0.stream == 2 }?.duration == 32_000_000)
    }

    @Test("a span several keyframes wide equals its one-keyframe spans joined")
    func wideSpanEqualsItsPartsJoined() async throws {
        let demuxer = try await MediaDemuxer.open(
            InMemoryRandomAccessReader(data: Self.fixture("h264-mkvmerge", "mkv")))

        let wide = try await demuxer.packets(from: 5, to: 9)
        var parts: [DemuxedPacket] = []
        for lower in 5..<9 {
            parts += try await demuxer.packets(from: lower, to: lower + 1)
        }

        #expect(Self.samples(wide) == Self.samples(parts))
    }

    private struct ShareGone: Error {}

    /// Serves the file, except that every read throws while `failing` is set.
    private actor FlakyReader: RandomAccessReading {
        private let backing: InMemoryRandomAccessReader
        private var failing = false

        init(data: Data) { backing = InMemoryRandomAccessReader(data: data) }

        func setFailing(_ failing: Bool) { self.failing = failing }

        var fileSize: UInt64 { get async throws { try await backing.fileSize } }

        func read(offset: UInt64, length: Int) async throws -> Data {
            if failing { throw ShareGone() }
            return try await backing.read(offset: offset, length: length)
        }
    }

    @Test("a read error surfaces as the reader's own error, and the next read starts clean")
    func readErrorSurfacesAndDoesNotStick() async throws {
        let reader = FlakyReader(data: try Self.fixture("h264-ffmpeg", "mkv"))
        let demuxer = try await MediaDemuxer.open(reader)
        let intact = try await demuxer.packets(from: 20, to: 22)
        _ = try await demuxer.packets(from: 0, to: 1)

        await reader.setFailing(true)
        await #expect(throws: ShareGone.self) {
            _ = try await demuxer.packets(from: 20, to: 22)
        }

        await reader.setFailing(false)
        #expect(try await demuxer.packets(from: 20, to: 22) == intact)
    }

    @Test("a container that cannot be read in spans is refused at open, by name")
    func nonMatroskaContainerIsRefused() async throws {
        let url = try #require(Bundle.module.url(
            forResource: "tiny", withExtension: "mp4", subdirectory: "Fixtures"))

        await #expect {
            _ = try await MediaDemuxer.open(InMemoryRandomAccessReader(data: try Data(contentsOf: url)))
        } throws: {
            if case MediaDemuxer.OpenFailure.unsupportedContainer(let name) = $0 { name.contains("mp4") } else { false }
        }
    }

    @Test("bytes that are no media file are refused at open")
    func unrecognizedBytesAreRefused() async {
        await #expect {
            _ = try await MediaDemuxer.open(InMemoryRandomAccessReader(data: Data(repeating: 0x5A, count: 4096)))
        } throws: {
            if case MediaDemuxer.OpenFailure.unreadableContainer = $0 { true } else { false }
        }
    }
}
