import CryptoKit
import Foundation
import Synchronization
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
    private static func expectedSamples(_ file: String) throws -> [Int: [Sample]] {
        let rows = try #require(
            JSONSerialization.jsonObject(with: fixture(String(file.prefix { $0 != "." }), "packets.json")) as? [[Any]])
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
        arguments: ["h264-ffmpeg", "h264-mkvmerge", "long-span", "ts-h264.ts", "m2ts-h264.m2ts", "flv-h264.flv", "avi-h264.avi"],
        Order.allCases)
    func spansFetchedOutOfOrderAddUpToTheFile(name: String, order: Order) async throws {
        let demuxer = try await BridgeFixture.demuxer(name)
        let count = try await demuxer.keyframes().count
        try #require(count > 4)

        var spans: [Int: [DemuxedPacket]] = [:]
        for lower in order.arranged(count) {
            spans[lower] = try await demuxer.packets(from: lower, to: lower + 1)
        }
        let joined = (0..<count).flatMap { spans[$0] ?? [] }

        #expect(Self.samples(joined) == (try Self.expectedSamples(name)))
    }

    @Test("a file with no index is given every keyframe of its video, each where a read of it starts",
          arguments: ["ts-h264.ts", "m2ts-h264.m2ts", "flv-h264.flv"])
    func fileWithNoIndexListsItsKeyframes(name: String) async throws {
        let demuxer = try await BridgeFixture.demuxer(name)
        let listed = try await demuxer.keyframes()
        let flagged = try #require(try Self.expectedSamples(name)[0]).filter(\.isKeyframe)

        #expect(listed.map { $0.time / 1_000_000 } == flagged.map(\.milliseconds))
        for index in listed.indices {
            let first = try #require(try await demuxer.packets(0, from: index, to: index + 1).first)
            #expect(Sample(first) == flagged[index])
        }
    }

    private static func sampled(_ data: Data, every spacing: Int64) async throws -> MediaDemuxer {
        let reader = InMemoryRandomAccessReader(data: data)
        return try await MediaDemuxer.open(
            SessionBlockCache(reader: reader, size: try await reader.fileSize),
            listing: .init(wholeReadSize: 0, sampling: .init(densestSpacing: spacing, largestSegment: spacing)))
    }

    @Test("a file sampled for its keyframes is cut at some of them, never at another picture, and its spans add up to exactly the file's packets",
          arguments: ["ts-h264.ts", "m2ts-h264.m2ts"])
    func sampledFileIsCutAtTrueKeyframes(name: String) async throws {
        let demuxer = try await Self.sampled(try BridgeFixture.data(name), every: 80_000)
        let listed = try await demuxer.keyframes()
        let flagged = try #require(try Self.expectedSamples(name)[0]).filter(\.isKeyframe).map(\.milliseconds)

        #expect(listed.first.map { $0.time / 1_000_000 } == flagged.first)
        #expect(Set(listed.map { $0.time / 1_000_000 }).isSubset(of: Set(flagged)))
        #expect((3..<flagged.count).contains(listed.count))

        var joined: [DemuxedPacket] = []
        for lower in listed.indices {
            joined += try await demuxer.packets(from: lower, to: lower + 1)
        }
        #expect(Self.samples(joined) == (try Self.expectedSamples(name)))
    }

    /// The fixture twice over: twelve seconds, then the same twelve seconds again.
    @Test("a file whose times start again part way through is refused, read whole or sampled",
          arguments: [Int64.max, 0])
    func timesThatStartAgainAreRefused(wholeReadSize: Int64) async throws {
        let part = try BridgeFixture.data("ts-h264.ts")
        let reader = InMemoryRandomAccessReader(data: part + part)
        let demuxer = try await MediaDemuxer.open(
            SessionBlockCache(reader: reader, size: try await reader.fileSize),
            listing: .init(
                wholeReadSize: wholeReadSize, sampling: .init(densestSpacing: 80_000, largestSegment: 80_000)))

        await #expect { _ = try await demuxer.keyframes() } throws: {
            guard case BridgeRefusal.timestampsRestart(let after) = $0 else { return false }
            return (9...11).contains(after)
        }
    }

    /// The fixture's times start below zero. libavformat's own index of it then held eight
    /// packets its seek had read through, which were taken for the file's keyframes.
    @Test("a transport stream whose clock wraps part way through lists every keyframe, half a second apart")
    func clockThatWrapsListsEveryKeyframe() async throws {
        let listed = try await BridgeFixture.demuxer("ts-clock-wraps.ts").keyframes()
        let first = try #require(listed.first?.time)

        #expect(first < 0)
        #expect(listed.map { ($0.time - first) / 1_000_000 } == (0..<8).map { Int64($0) * 500 })
    }

    /// libavformat searches 64 KB for the next packet, then hands over a picture or a frame it
    /// had begun, and with none left to hand over answers "try again". The stretch here is long
    /// enough to use up the three streams' and still not end.
    @Test("a transport stream with a long stretch that holds no packets lists the keyframes on both sides of it")
    func damagedStretchOfATransportStreamIsReadPast() async throws {
        let whole = try BridgeFixture.data("ts-h264.ts")
        var damaged = whole
        damaged.replaceSubrange(300_000..<650_000, with: Data(count: 350_000))
        let intact = try await MediaDemuxer.open(InMemoryRandomAccessReader(data: whole)).keyframes()

        let listed = try await MediaDemuxer.open(InMemoryRandomAccessReader(data: damaged)).keyframes()

        #expect(listed.filter { $0.position < 300_000 } == intact.filter { $0.position < 300_000 })
        #expect(listed.filter { $0.position >= 300_000 } == intact.filter { $0.position >= 650_000 })
        #expect(listed.count == 16)
    }

    /// Every cluster of the file, by an EBML walk of its Segment: where it starts and its time,
    /// in milliseconds as both fixtures store it.
    private static func clusters(in data: Data) -> [(position: Int64, milliseconds: Int64)] {
        let bytes = [UInt8](data)
        func vint(at offset: Int, keepingMarker: Bool) -> (value: Int64, length: Int) {
            let length = bytes[offset].leadingZeroBitCount + 1
            let first = keepingMarker ? Int64(bytes[offset]) : Int64(bytes[offset]) & (0xFF >> length)
            return (bytes[offset + 1..<offset + length].reduce(first) { $0 << 8 | Int64($1) }, length)
        }
        func element(at offset: Int) -> (id: Int64, data: Int, size: Int) {
            let id = vint(at: offset, keepingMarker: true)
            let size = vint(at: offset + id.length, keepingMarker: false)
            return (id.value, offset + id.length + size.length, Int(size.value))
        }
        let header = element(at: 0)
        let segment = element(at: header.data + header.size)
        var found: [(position: Int64, milliseconds: Int64)] = []
        var offset = segment.data
        while offset < min(segment.data + segment.size, bytes.count) {
            let child = element(at: offset)
            if child.id == 0x1F43_B675 {
                let first = element(at: child.data)
                let timestamp = first.id == 0xBF ? element(at: first.data + first.size) : first
                if timestamp.id == 0xE7 {
                    let value = bytes[timestamp.data..<timestamp.data + timestamp.size].reduce(Int64(0)) { $0 << 8 | Int64($1) }
                    found.append((Int64(offset), value))
                }
            }
            offset = child.data + child.size
        }
        return found
    }

    @Test("an audio read starts only where a cluster does, from wherever in the span before the search begins",
          arguments: ["h264-ffmpeg", "h264-mkvmerge", "long-span"])
    func clusterSearchFindsOnlyClusters(name: String) async throws {
        let data = try Self.fixture(name, "mkv")
        let clusters = Self.clusters(in: data)
        try #require(clusters.count > 4)
        let demuxer = try await MediaDemuxer.open(InMemoryRandomAccessReader(data: data))
        let keyframes = try await demuxer.keyframes()

        for (previous, keyframe) in zip(keyframes, keyframes.dropFirst()) {
            for offset in stride(from: previous.position, to: keyframe.position, by: 4096) {
                let expected = clusters.first {
                    $0.position >= offset && $0.position < keyframe.position
                        && (previous.time...keyframe.time).contains($0.milliseconds * 1_000_000)
                }?.position
                #expect(try await demuxer.clusterStart(from: offset, before: keyframe, after: previous.time) == expected)
            }
        }
    }

    /// Serves the file and keeps where each read started.
    /// Where each tag of an FLV starts, read forwards: a tag is eleven bytes of header, its
    /// data, and four bytes of its size.
    private static func tagStarts(in data: Data) -> [Int64] {
        var starts: [Int64] = []
        var at = 13
        while at + 11 <= data.count {
            starts.append(Int64(at))
            at += 11 + data[(at + 1)...(at + 3)].reduce(0) { $0 << 8 | Int($1) } + 4
        }
        return starts
    }

    @Test("an FLV's audio read starts only where a tag does: the last one at or before where the search begins")
    func tagSearchFindsOnlyTags() async throws {
        let data = try BridgeFixture.data("flv-h264.flv")
        let demuxer = try await BridgeFixture.demuxer("flv-h264.flv")
        let keyframes = try await demuxer.keyframes()
        let tags = Self.tagStarts(in: data)

        for keyframe in keyframes.dropFirst() {
            #expect(tags.contains(keyframe.position))
            for back in [1, 500, 20_000, 72_192] as [Int64] {
                let offset = max(keyframe.position - back, 13)
                let found = try await demuxer.tagStart(atOrBefore: offset, before: keyframe)
                #expect(found == tags.last { $0 <= offset })
            }
        }
    }

    @Test("an FLV written without the sizes its tags are found by has no tag to start an audio read at")
    func tagSearchNeedsTheSizes() async throws {
        var data = try BridgeFixture.data("flv-h264.flv")
        let keyframe = try #require(try await BridgeFixture.demuxer("flv-h264.flv").keyframes().last)
        data.replaceSubrange(Int(keyframe.position - 4)..<Int(keyframe.position), with: Data(count: 4))
        let demuxer = try await MediaDemuxer.open(InMemoryRandomAccessReader(data: data))

        #expect(try await demuxer.tagStart(atOrBefore: keyframe.position - 500, before: keyframe) == nil)
    }

    private final class OffsetsReader: RandomAccessReading {
        let backing: InMemoryRandomAccessReader
        private let offsets = Mutex<[Int64]>([])

        init(data: Data) { backing = InMemoryRandomAccessReader(data: data) }

        var fileSize: UInt64 { get async throws { try await backing.fileSize } }

        func read(offset: UInt64, length: Int) async throws -> Data {
            offsets.withLock { $0.append(Int64(offset)) }
            return try await backing.read(offset: offset, length: length)
        }

        func takeOffsets() -> [Int64] { offsets.withLock { defer { $0 = [] }; return $0 } }
    }

    @Test("the audio of the segment after a 32-second keyframe interval is read from at most eight seconds of it back")
    func audioAfterALongSpanReadsEightSecondsBack() async throws {
        let data = try Self.fixture("long-span", "mkv")
        let reader = OffsetsReader(data: data)
        // Blocks of 4 KB, and few enough kept that what the open read is gone again.
        let demuxer = try await MediaDemuxer.open(SessionBlockCache(
            reader: reader, size: UInt64(data.count), blockSize: 4096, bytesKept: 64 << 10))
        let keyframes = try await demuxer.keyframes()
        try #require(keyframes[1].time == 32_000_000_000)
        _ = reader.takeOffsets()

        let audio = try await demuxer.packets(1, from: 1, to: 2)

        let eightSeconds = (keyframes[1].position - keyframes[0].position) / 4
        let first = try #require(reader.takeOffsets().min())
        #expect(first >= keyframes[1].position - eightSeconds - 4096)
        #expect(first < keyframes[1].position)
        #expect(audio == (try await MediaDemuxer.open(InMemoryRandomAccessReader(data: data)).packets(1, from: 1, to: 2)))
    }

    @Test("audio after a long span with no cluster in the eight seconds before its keyframe starts at the nearest cluster further back, not at the span's start")
    func audioReadLooksFurtherBackForACluster() async throws {
        let data = try Self.fixture("sparse-clusters", "mkv")
        let reader = OffsetsReader(data: data)
        let demuxer = try await MediaDemuxer.open(SessionBlockCache(
            reader: reader, size: UInt64(data.count), blockSize: 4096, bytesKept: 64 << 10))
        let keyframes = try await demuxer.keyframes()
        try #require(keyframes[1].time == 50_000_000_000)
        _ = reader.takeOffsets()

        let audio = try await demuxer.packets(1, from: 1, to: 2)

        // The cluster at 30 s is three fifths into the span, and the search for it reads from
        // twice as far back as the window that missed it: past the span's first quarter.
        let span = keyframes[1].position - keyframes[0].position
        let first = try #require(reader.takeOffsets().min())
        #expect(first > keyframes[0].position + span / 4)
        #expect(audio == (try await MediaDemuxer.open(InMemoryRandomAccessReader(data: data)).packets(1, from: 1, to: 2)))
    }

    @Test("an audio read looks back no further than the span before its keyframe, whose entries may share a time")
    func audioLookbackStaysWithinTheSpan() {
        let before = IndexedKeyframe(time: 50_000_000_000, position: 3 << 30)
        #expect(MediaDemuxer.audioLookback(before: before, after: IndexedKeyframe(time: 50_000_000_000, position: 1 << 30)) == 2 << 30)
        // Eight of the span's ten seconds.
        #expect(MediaDemuxer.audioLookback(before: before, after: IndexedKeyframe(time: 40_000_000_000, position: 2 << 30)) == (8 << 30) / 10)
    }

    @Test("a stream's codec string names its sample entry and profile", arguments: [
        // The fixture's `hvcC` holds profile 1, compatibility flags 60000000, constraint byte
        // 90 and level 30.
        ("frame-numbers-hevc", ["hvc1.1.6.L30.90", "ac-3"]),
        ("he-aac", ["avc1.64000b", "mp4a.40.5"]),
        ("he-aac-v2", ["avc1.64000b", "mp4a.40.29"]),
        ("flac", ["avc1.64000b", "fLaC"]),
        ("eac3", ["avc1.64000b", "ec-3"]),
        ("opus", ["avc1.64000b", "Opus"]),
        // The fixture's `av1C` holds profile 0 (Main), level 0, the main tier and 8 bits.
        ("av1", ["av01.0.00M.08", "mp4a.40.2"]),
        // The encodes of `h264-ffmpeg` and `frame-numbers-hevc`, whose profile and level a
        // transport stream holds in parameter sets behind start codes, not in a record. The
        // HEVC set's constraint bytes hold the `03` that keeps a start code out of them.
        ("ts-h264.ts", ["avc1.640014", "mp4a.40.2", "ac-3"]),
        ("ts-hevc-open-gop.ts", ["hvc1.1.6.L30.90", "ac-3"]),
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
        #expect(streams[0].parameters.pixelSize == (160, 90))
        #expect(streams[0].frameRate == .init(numerator: 24, denominator: 1))
        #expect(streams.map(\.tick) == [1_000_000, 1_000_000, 1_000_000])
        #expect(demuxer.duration == 12_031_000_000)
        #expect(demuxer.fileSize == 930_719)

        let first = try await demuxer.packets(from: 0, to: 1)
        #expect(first.first { $0.stream == 0 }?.duration == 41_000_000)
        #expect(first.first { $0.stream == 2 }?.duration == 32_000_000)
    }

    @Test("each audio stream reports its language, its title, its channels and whether the file marks it as the default")
    func audioStreamsReportTheirTags() async throws {
        let audio = try await BridgeFixture.demuxer("four-audio-tracks").streams.filter { $0.kind == .audio }

        #expect(audio.map(\.language) == ["eng", "jpn", "jpn", "ger"])
        #expect(audio.map(\.title) == [nil, "Surround", nil, nil])
        #expect(audio.map(\.isDefault) == [false, true, false, false])
        #expect(audio.map(\.parameters.channelCount) == [2, 6, 2, 2])
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
        let data = try Self.fixture("h264-ffmpeg", "mkv")
        let intact = try await MediaDemuxer.open(InMemoryRandomAccessReader(data: data)).packets(from: 20, to: 22)
        // The demuxer keeps what it has read, so the failing read is of a part it has not.
        let reader = FlakyReader(data: data)
        let demuxer = try await MediaDemuxer.open(reader)
        _ = try await demuxer.packets(from: 0, to: 1)

        await reader.setFailing(true)
        await #expect(throws: ShareGone.self) {
            _ = try await demuxer.packets(from: 20, to: 22)
        }

        await reader.setFailing(false)
        #expect(try await demuxer.packets(from: 20, to: 22) == intact)
    }

    /// Answers every read with at most 100 KB, as a share under strain does.
    private struct ShortReader: RandomAccessReading {
        let backing: InMemoryRandomAccessReader

        var fileSize: UInt64 { get async throws { try await backing.fileSize } }

        func read(offset: UInt64, length: Int) async throws -> Data {
            try await backing.read(offset: offset, length: min(length, 100_000))
        }
    }

    @Test("a reader that answers with less than was asked loses no packet")
    func shortReadsLoseNothing() async throws {
        let data = try Self.fixture("h264-ffmpeg", "mkv")
        let whole = try await MediaDemuxer.open(InMemoryRandomAccessReader(data: data))
        let short = try await MediaDemuxer.open(ShortReader(backing: InMemoryRandomAccessReader(data: data)))
        let count = try await whole.keyframes().count

        #expect(try await short.packets(from: 0, to: count) == whole.packets(from: 0, to: count))
        #expect(try await short.packets(from: 20, to: 22) == whole.packets(from: 20, to: 22))
    }

    @Test("a container that cannot be read in spans is described, and has no keyframe list",
          arguments: ["refused-asf-h264.asf"])
    func containerNotReadInSpansIsDescribedOnly(name: String) async throws {
        let demuxer = try await BridgeFixture.demuxer(name)

        #expect(demuxer.streams.map(\.parameters.codecName) == ["h264", "ac3"])
        await #expect(throws: BridgeRefusal.container(name: "asf")) { _ = try await demuxer.keyframes() }
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
