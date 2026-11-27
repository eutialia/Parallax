import Foundation
import Testing
import ParallaxCoreTestSupport
@testable import ParallaxPlayback

/// Where an audio read before a span's keyframe starts. A delivery reads its fixtures a 2 MB
/// read at a time, so where in a read the audio starts is not something its ends show.
@Suite("Where an audio read starts")
struct AudioReadStartProperties {

    private static let cases = 400

    /// Every cluster of the file, by an EBML walk of its Segment: where it starts and its time,
    /// in milliseconds as each fixture stores it.
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

    private static func reading(_ data: Data) -> (Int64, Int) -> Data {
        { offset, length in data[Int(offset)..<min(Int(offset) + length, data.count)] }
    }

    @Test("an audio read in a Matroska file starts only where a cluster does: the first from where the search begins that is timed in the span",
          arguments: ["h264-ffmpeg", "h264-mkvmerge", "long-span", "sparse-clusters"])
    func matroskaReadStartsAtACluster(name: String) throws {
        let data = try BridgeFixture.data(name)
        let clusters = Self.clusters(in: data)
        try #require(clusters.count > 4)
        let lastTime = try #require(clusters.last).milliseconds * 1_000_000
        let seed = UInt64(0x7374_6172_7431)
        var random = SeededGenerator(seed: seed)
        for _ in 0..<Self.cases {
            let keyframe = IndexedKeyframe(
                time: .random(in: 0...lastTime + 1_000_000_000, using: &random),
                position: .random(in: 1...Int64(data.count), using: &random))
            let previous = IndexedKeyframe(time: .random(in: 0...keyframe.time, using: &random), position: 0)
            let offset = Int64.random(in: 0..<keyframe.position, using: &random)

            let start = MediaDemuxer.audioReadStart(
                .matroskaClusters, from: offset, before: keyframe, after: previous,
                nanoseconds: { $0 * 1_000_000 }, bytes: Self.reading(data))

            let expected = clusters.first {
                (offset..<keyframe.position).contains($0.position)
                    && (previous.time...keyframe.time).contains($0.milliseconds * 1_000_000)
            }?.position
            #expect(start == expected, "seed \(seed): from \(offset) before \(keyframe), after \(previous.time)")
        }
        // A cluster more than a read's window past the one before it, its ID and Timestamp
        // cut by the end of the first window the search reads.
        let window: Int64 = 1 << 16
        let end = IndexedKeyframe(time: lastTime + 1_000_000_000, position: Int64(data.count))
        for (before, cluster) in zip(clusters, clusters.dropFirst()) where cluster.position - before.position > window + 12 {
            for cut in Int64(1)...12 {
                let start = MediaDemuxer.audioReadStart(
                    .matroskaClusters, from: cluster.position - window + cut, before: end,
                    after: IndexedKeyframe(time: 0, position: 0), nanoseconds: { $0 * 1_000_000 }, bytes: Self.reading(data))
                #expect(start == cluster.position, "the cluster at \(cluster.position), \(cut) bytes of it in the first window")
            }
        }
    }

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
    func flashVideoReadStartsAtATag() throws {
        let data = try BridgeFixture.data("flv-h264.flv")
        let tags = Self.tagStarts(in: data)
        try #require(tags.count > 4)
        let seed = UInt64(0x7374_6172_7432)
        var random = SeededGenerator(seed: seed)
        for _ in 0..<Self.cases {
            let keyframe = IndexedKeyframe(time: 0, position: try #require(tags.dropFirst().randomElement(using: &random)))
            let offset = Int64.random(in: 13...keyframe.position, using: &random)

            let start = MediaDemuxer.audioReadStart(
                .flashVideoTags(0), from: offset, before: keyframe, after: keyframe,
                nanoseconds: { $0 }, bytes: Self.reading(data))

            #expect(start == tags.last { $0 <= offset }, "seed \(seed): from \(offset) before \(keyframe.position)")
        }
    }

    @Test("an audio read looks back eight seconds of the span before its keyframe in a Matroska file, at the span's rate, and never further than the span, whose entries may share a time; elsewhere as far as the container's own distance")
    func audioLookback() {
        let seed = UInt64(0x7374_6172_7433)
        var generator = SeededGenerator(seed: seed)
        for _ in 0..<Self.cases {
            let previous = IndexedKeyframe(
                time: Int64.random(in: 0...(3_600 * 1_000_000_000), using: &generator),
                position: Int64.random(in: 0...(40 << 30), using: &generator))
            // Spans of no time at all, of under eight seconds and of minutes.
            let lasting = [Int64(0), .random(in: 1...8_000_000_000, using: &generator),
                           .random(in: 8_000_000_001...(300 * 1_000_000_000), using: &generator)]
                .randomElement(using: &generator)!
            // Spans of no bytes, of a few, whose eight seconds round to none, and of gigabytes.
            let bytes = [Int64(0), .random(in: 1...64, using: &generator), .random(in: 65...(2 << 30), using: &generator)]
                .randomElement(using: &generator)!
            let keyframe = IndexedKeyframe(time: previous.time + lasting, position: previous.position + bytes)
            let span = keyframe.position - previous.position
            let lookback = MediaDemuxer.audioLookback(.matroskaClusters, before: keyframe, after: previous)
            let own = Int64.random(in: 1...(8 << 20), using: &generator)
            let context = "seed \(seed): \(span) bytes over \(lasting) ns looked back \(lookback)"

            #expect(lookback >= 1 && lookback <= max(span, 1), "\(context)")
            if lasting > 8_000_000_000 {
                let eightSeconds = Double(span) * 8e9 / Double(lasting)
                #expect(abs(Double(lookback) - max(eightSeconds, 1)) <= 1, "\(context)")
            } else {
                #expect(lookback == max(span, 1), "\(context)")
            }
            #expect(MediaDemuxer.audioLookback(.bytesBefore(own), before: keyframe, after: previous) == own, "\(context)")
            #expect(MediaDemuxer.audioLookback(.flashVideoTags(own), before: keyframe, after: previous) == own, "\(context)")
        }
    }

    @Test("an audio read looks twice as far back each time it finds no place to start, and starts at the previous keyframe once the look reaches it")
    func audioReadLooksFurtherBack() {
        let seed = UInt64(0x7374_6172_7434)
        var random = SeededGenerator(seed: seed)
        for _ in 0..<Self.cases {
            let position = Int64.random(in: 2...(1 << 30), using: &random)
            let anyFloor = Int64.random(in: 0..<position, using: &random)
            let back = Int64.random(in: 1...max(1, (position - anyFloor) / [1, 4, 64, 4096].randomElement(using: &random)!), using: &random)
            // A third of the floors lie exactly where a look reaches.
            let reached = position - back << Int64.random(in: 0...12, using: &random)
            let floor = reached >= 0 && Int.random(in: 0..<3, using: &random) == 0 ? reached : anyFloor
            // Places a read can begin, from none before the keyframe to many.
            let count = [0, 1, 3, 40].randomElement(using: &random)!
            let places = (0..<count).map { _ in Int64.random(in: 0..<position, using: &random) }.sorted()

            let (start, looked) = MediaDemuxer.audioReadPlace(lookingBack: back, before: position, floor: floor) { from in
                places.first { $0 >= from }
            }

            let context = "seed \(seed): back \(back) from \(position) to \(floor) over \(places) found \(String(describing: start)) at \(looked)"
            let doublings = (looked / back).trailingZeroBitCount
            #expect(looked % back == 0 && looked / back == 1 << doublings, "\(context)")
            let from = position - looked
            if let start {
                #expect(from > floor, "\(context)")
                #expect(start == places.first { $0 >= from }, "\(context)")
            } else {
                #expect(from <= floor, "\(context)")
            }
            if looked > back {
                // The look before found nothing, and was still after the floor.
                let before = position - looked / 2
                #expect(before > floor && !places.contains { $0 >= before }, "\(context)")
            }
        }
    }
}
