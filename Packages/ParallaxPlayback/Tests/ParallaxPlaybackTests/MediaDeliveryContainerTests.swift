import Foundation
import Synchronization
import Testing
import ParallaxCore
import ParallaxCoreTestSupport
import ParallaxTestScaling
import ParallaxPlayback

/// How a bridged delivery reads each container, seen in what it serves: its playlists, and its
/// segments read back by libavformat's own demuxer against that demuxer's reading of the source.
@Suite("MediaDelivery — reading each container", .scaledTimeLimit())
struct MediaDeliveryContainerTests {

    /// A rendition and the source stream it carries. `reframed` when the source stores the
    /// stream's samples in another form than an MP4 does, H.264 behind start codes or AAC behind
    /// ADTS headers, so only their count, keyframes and times compare. Not `timed` when the
    /// readback cannot give the source's times: it holds a timescale in whole ticks a second.
    struct Carried: Sendable {
        let rendition: String
        let stream: Int
        let reframed: Bool
        let timed: Bool

        init(_ rendition: String, _ stream: Int, reframed: Bool = false, timed: Bool = true) {
            (self.rendition, self.stream, self.reframed, self.timed) = (rendition, stream, reframed, timed)
        }
    }

    struct Container: Sendable, CustomTestStringConvertible {
        let name: String
        let carried: [Carried]
        var testDescription: String { name }
    }

    static let containers = [
        // ffmpeg writes a CRC-32 at the start of each cluster, mkvmerge does not.
        Container(name: "h264-ffmpeg", carried: [.init("v", 0), .init("a0", 1), .init("a1", 2)]),
        Container(name: "h264-mkvmerge", carried: [.init("v", 0), .init("a0", 1), .init("a1", 2)]),
        // A 32-second keyframe interval, and one of 50 seconds with no cluster in the eight
        // seconds before its end.
        Container(name: "long-span", carried: [.init("v", 0), .init("a0", 1)]),
        Container(name: "sparse-clusters", carried: [.init("v", 0), .init("a0", 1)]),
        Container(name: "ts-h264.ts", carried: [.init("v", 0, reframed: true), .init("a0", 1, reframed: true), .init("a1", 2)]),
        Container(name: "m2ts-h264.m2ts", carried: [.init("v", 0, reframed: true), .init("a0", 1, reframed: true), .init("a1", 2)]),
        Container(name: "flv-h264.flv", carried: [.init("v", 0), .init("a0", 1)]),
        // Its AC-3 is timed in 32 ms ticks, 31.25 a second.
        Container(name: "avi-h264.avi", carried: [.init("v", 0, reframed: true), .init("a0", 1, timed: false)]),
        Container(name: "asf-h264.asf", carried: [.init("v", 0, reframed: true), .init("a0", 1)]),
        // Its MP2 is converted, so only its video compares.
        Container(name: "numbered-h264.mpg", carried: [.init("v", 0, reframed: true)]),
        // HEVC with B-pictures under `hev1`, which AVPlayer does not take as stored.
        Container(name: "numbered-hevc-hev1.mp4", carried: [.init("v", 0), .init("a0", 1)]),
    ]

    /// A device that plays no DTS, as none of Apple's do, so an MP4 that carries it is bridged.
    static let device = AVPlayerSupport(
        containers: [.mp4, .mov, .hls], videoCodecs: Set(VideoCodec.allCases),
        audioCodecs: Set(AudioCodec.allCases).subtracting([.dts]), decodesH264High10: true)

    /// Each order makes every segment follow one it does not continue from.
    enum Order: String, CaseIterable, Sendable {
        case descending, oddsThenEvens

        func arranged(_ indices: Range<Int>) -> [Int] {
            switch self {
            case .descending: indices.reversed()
            case .oddsThenEvens: indices.filter { $0 % 2 == 1 } + indices.filter { $0 % 2 == 0 }
            }
        }
    }

    /// libavformat's reading of a fixture, stream by stream, in file order.
    static func source(_ data: Data, named file: String) throws -> [Int: [ReadbackSample]] {
        let parts = file.split(separator: ".")
        return Dictionary(grouping: try readBackSamples(of: data, pathExtension: parts.count > 1 ? String(parts[1]) : "mkv"), by: \.stream)
    }

    static func source(_ file: String) throws -> [Int: [ReadbackSample]] {
        try source(BridgeFixture.data(file), named: file)
    }

    static func seconds(_ ticks: Int64, _ timescale: Int64) -> Double { Double(ticks) / Double(timescale) }

    /// When a sample shows, in nanoseconds: its presentation time, or where its container gives
    /// none, its decode time.
    static func nanoseconds(showing sample: ReadbackSample) -> Int64 {
        let ticks = sample.presentation == .min ? sample.decode : sample.presentation
        return Int64((Double(ticks) * 1e9 / Double(sample.timescale)).rounded())
    }

    /// How `served` differs from `source`: in count, bytes unless reframed, or in time by more
    /// than two milliseconds once both are on one timeline. Matroska times a frame to the
    /// millisecond, and mkvmerge's AAC strays up to two from the even steps the bridge keeps it
    /// on. Nil when it does not.
    static func difference(_ served: [ReadbackSample], from source: [ReadbackSample], reframed: Bool, timed: Bool = true) -> String? {
        guard served.count == source.count else { return "\(served.count) samples for \(source.count)" }
        if !reframed, let place = source.indices.first(where: { served[$0].md5 != source[$0].md5 }) {
            return "sample \(place)'s bytes"
        }
        guard timed else { return nil }
        let offsets = source.indices.compactMap { place -> Double? in
            source[place].presentation == .min ? nil
                : seconds(served[place].presentation, served[place].timescale)
                    - seconds(source[place].presentation, source[place].timescale)
        }
        let stray = (offsets.max() ?? 0) - (offsets.min() ?? 0)
        return stray <= 0.002 + 1e-9 ? nil : String(format: "times stray by %.3f ms", stray * 1000)
    }

    /// The served samples are the source's, each marked a keyframe where the source marks one.
    static func expect(
        _ served: [ReadbackSample], carrying carried: Carried, of source: [Int: [ReadbackSample]], in container: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let source = source[carried.stream] ?? []
        let difference = Self.difference(served, from: source, reframed: carried.reframed, timed: carried.timed)
        let wronglyMarked = zip(served, source).enumerated().filter { $0.element.0.isKeyframe != $0.element.1.isKeyframe }.map(\.offset)
        let expectations = {
            #expect(difference == nil, "\(carried.rendition): \(difference ?? "")", sourceLocation: sourceLocation)
            #expect(wronglyMarked == [], "\(carried.rendition): samples \(wronglyMarked) marked otherwise", sourceLocation: sourceLocation)
        }
        if container.hasSuffix(".mpg"), carried.rendition == "v" {
            withKnownIssue(Self.programStreamVideo, expectations)
        } else {
            expectations()
        }
    }

    /// Measured: libavformat reads B-pictures at 1.79 s and every 2 s after it as keyframes in
    /// the served segments, which the source marks as none; sampled, a keyframe goes unmarked and
    /// times stray by 125 ms; and a segment's bytes differ from one delivery to the next.
    static let programStreamVideo: Comment = "A program stream's video segments mark pictures that are no keyframes"

    /// Each segment of `rendition` read back on its own, behind the init segment.
    static func segments(_ rendition: String, of file: DeliveredFile) async throws -> [[ReadbackSample]] {
        let initSegment = try await file.bytes("\(rendition)-init.mp4")
        var segments: [[ReadbackSample]] = []
        for index in try await file.segmentSeconds(of: "\(rendition).m3u8").indices {
            let segment = try await file.bytes("\(rendition)-\(index).m4s")
            segments.append(try readBackSamples(of: initSegment + segment, pathExtension: "mp4"))
        }
        return segments
    }

    static func delivered<Value>(
        _ file: DeliveredFile, _ body: (DeliveredFile) async throws -> Value
    ) async throws -> Value {
        do {
            let value = try await body(file)
            await file.stop()
            return value
        } catch {
            await file.stop()
            throw error
        }
    }

    // MARK: - Segments

    @Test("every rendition's segments, fetched out of order, hold exactly the file's samples, each at its own time",
          arguments: Self.containers, Order.allCases)
    func segmentsHoldExactlyTheFilesSamples(container: Container, order: Order) async throws {
        let source = try Self.source(container.name)
        let served = try await Self.delivered(try await DeliveredFile.start(container.name, support: Self.device)) { file in
            try await container.carried.asyncMap {
                try readBackSamples(of: try await file.rendition($0.rendition, fetchedIn: order.arranged), pathExtension: "mp4")
            }
        }

        for (carried, samples) in zip(container.carried, served) {
            Self.expect(samples, carrying: carried, of: source, in: container.name)
        }
    }

    @Test("segments of every rendition asked for all at once are the ones asked for one by one, whatever the container",
          arguments: ["h264-ffmpeg", "ts-h264.ts", "flv-h264.flv", "avi-h264.avi", "asf-h264.asf", "numbered-h264.mpg", "numbered-h264-dts.mp4"])
    func segmentsAskedForAtOnceMatchOneByOne(name: String) async throws {
        let (paths, oneByOne) = try await Self.delivered(try await DeliveredFile.start(name, support: Self.device)) { file in
            let master = try await file.master
            let renditions = ["v"] + master.split(separator: "\n").filter { $0.contains("TYPE=AUDIO") }.compactMap {
                Self.attribute("URI", of: $0).map { String($0.prefix { $0 != "." }) }
            }
            var paths: [String] = []
            for rendition in renditions {
                for index in try await file.segmentSeconds(of: "\(rendition).m3u8").indices { paths.append("\(rendition)-\(index).m4s") }
            }
            return (paths, try await paths.asyncMap { try await file.bytes($0) })
        }
        let atOnce = try await Self.delivered(try await DeliveredFile.start(name, support: Self.device)) { file in
            try await withThrowingTaskGroup(of: (String, Data).self) { group in
                for path in paths { group.addTask { (path, try await file.bytes(path)) } }
                return try await group.reduce(into: [String: Data]()) { $0[$1.0] = $1.1 }
            }
        }

        #expect(paths.count > 6)
        let differing = paths.filter { atOnce[$0] != oneByOne[paths.firstIndex(of: $0)!] }
        if name.hasSuffix(".mpg") {
            withKnownIssue(Self.programStreamVideo) { #expect(differing == []) }
        } else {
            #expect(differing == [])
        }
    }

    @Test("a file's video, indexed or not, is cut at its keyframes: at the first one two seconds or more past the last cut, by when its picture shows",
          arguments: [
            "h264-ffmpeg", "h264-mkvmerge", "avi-h264.avi", "numbered-h264-dts.mp4",
            "ts-h264.ts", "m2ts-h264.m2ts", "flv-h264.flv", "asf-h264.asf",
            // Its times start below zero and wrap, and libavformat's own index of it held packets
            // that are no keyframes.
            "ts-clock-wraps.ts",
          ])
    func videoIsCutAtItsKeyframes(name: String) async throws {
        let keyframes = try Self.source(name)[0, default: []].filter(\.isKeyframe).map(Self.nanoseconds(showing:))
        let cuts = keyframes.reduce(into: [Int64]()) { cuts, time in
            if let last = cuts.last, time - last < 2_000_000_000 { return }
            cuts.append(time)
        }
        let segments = try await Self.delivered(try await DeliveredFile.start(name, support: Self.device)) { try await Self.segments("v", of: $0) }
        let starts = try segments.map { try #require($0.first) }

        #expect(starts.allSatisfy { $0.isKeyframe })
        let served = starts.map(Self.nanoseconds(showing:))
        #expect(served.count == cuts.count, "\(served) for \(cuts)")
        for (served, cut) in zip(served, cuts) {
            #expect(abs((served - (starts.first.map(Self.nanoseconds(showing:)) ?? 0)) - (cut - cuts[0])) <= 1_000_000, "\(served) for \(cut)")
        }
    }

    /// An audio segment holds the frames timed from its video segment's first keyframe, by when
    /// that keyframe's picture shows, up to the next segment's. A frame converted to FLAC starts
    /// on the keyframe's time exactly.
    ///
    /// An MP4 indexes a keyframe by its decode time, and the bridge places its picture by the
    /// first picture's show delay. `early` is how much longer a later keyframe's delay is: the
    /// HEVC's first picture shows two pictures after it is decoded and its later keyframes four,
    /// 83.3 ms at 24 a second, and its audio segments start up to that much early.
    @Test("each audio segment after the first starts with the first frame timed at or after its video segment's first picture",
          arguments: [
            ("h264-mkvmerge", 0.0), ("ts-h264.ts", 0), ("flv-h264.flv", 0), ("avi-h264.avi", 0),
            ("numbered-hevc-hev1.mp4", 0.0834), ("numbered-h264-dts.mp4", 0),
          ])
    func audioSegmentStartsWithItsVideo(name: String, early: Double) async throws {
        let (video, audio) = try await Self.delivered(try await DeliveredFile.start(name, support: Self.device)) { file in
            (try await Self.segments("v", of: file), try await Self.segments("a0", of: file))
        }

        #expect(audio.count > 2)
        for index in 1..<min(video.count, audio.count) {
            let picture = try #require(video[index].first)
            let frames = audio[index]
            let first = try #require(frames.first)
            let next = try #require(frames.dropFirst().first)
            let shows = Self.seconds(picture.presentation, picture.timescale)
            let heard = Self.seconds(first.presentation, first.timescale)
            let frame = Self.seconds(next.presentation - first.presentation, first.timescale)
            #expect(heard >= shows - early - 0.001 && heard < shows + frame + 0.001, "segment \(index): heard at \(heard), shown at \(shows)")
        }
    }

    // MARK: - Damaged files

    /// libavformat searches 64 KB for the next packet, then hands over a picture or a frame it
    /// had begun, and with none left to hand over answers "try again". The stretch here is long
    /// enough to use up the three streams' and still not end.
    @Test("a transport stream with a long stretch that holds no packets is delivered with the keyframes on both sides of it")
    func damagedStretchOfATransportStreamIsReadPast() async throws {
        let whole = try BridgeFixture.data("ts-h264.ts")
        var damaged = whole
        damaged.replaceSubrange(300_000..<650_000, with: Data(count: 350_000))
        let intact = try await Self.delivered(try await DeliveredFile.start("ts-h264.ts")) { file in
            (Array(try await Self.segments("v", of: file).joined()), try await file.segmentSeconds(of: "v.m3u8"))
        }

        let reader = InMemoryRandomAccessReader(data: damaged)
        let (video, seconds) = try await Self.delivered(try await DeliveredFile.start(reading: reader, named: "ts-h264.ts")) { file in
            (try await Self.segments("v", of: file), try await file.segmentSeconds(of: "v.m3u8"))
        }

        #expect(video.allSatisfy { $0.first?.isKeyframe == true })
        let keyframes = video.joined().filter(\.isKeyframe).map(\.presentation)
        let intactKeyframes = intact.0.filter(\.isKeyframe).map(\.presentation)
        #expect(keyframes.first == intactKeyframes.first)
        #expect(keyframes.last == intactKeyframes.last)
        #expect(Set(keyframes).isSubset(of: intactKeyframes))
        #expect(keyframes.count == 16)
        #expect(abs(seconds.reduce(0, +) - intact.1.reduce(0, +)) < 0.001)
    }

    /// Where each tag of an FLV starts, read forwards: a tag is eleven bytes of header, its
    /// data, and four bytes of its size.
    private static func tagStarts(in data: Data) -> [Int] {
        var starts: [Int] = []
        var at = 13
        while at + 11 <= data.count {
            starts.append(at)
            at += 11 + data[(at + 1)...(at + 3)].reduce(0) { $0 << 8 | Int($1) } + 4
        }
        return starts
    }

    /// The bridge finds where an FLV's audio read can start by stepping back from a keyframe's
    /// tag through the sizes stored before each tag. Here the size before the last keyframe's
    /// tag is gone.
    @Test("an FLV written without the sizes its tags are found by still delivers every audio frame")
    func flashVideoWithoutTagSizesKeepsItsAudio() async throws {
        var data = try BridgeFixture.data("flv-h264.flv")
        // A video tag is type 9, and its first byte of data holds the frame type, 1 for a keyframe.
        let keyframe = try #require(Self.tagStarts(in: data).last { data[$0] == 9 && data[$0 + 11] >> 4 == 1 })
        data.replaceSubrange(keyframe - 4..<keyframe, with: Data(count: 4))
        // libavformat's own reading of the damaged file is the oracle.
        let source = try Self.source(data, named: "flv-h264.flv")

        let audio = try await Self.delivered(
            try await DeliveredFile.start(reading: InMemoryRandomAccessReader(data: data), named: "flv-h264.flv")
        ) { file in
            try readBackSamples(of: try await file.rendition("a0", fetchedIn: Order.descending.arranged), pathExtension: "mp4")
        }

        #expect(Self.difference(audio, from: source[1] ?? [], reframed: false) == nil)
    }

    /// The fixture twice over: twelve seconds, then the same twelve seconds again.
    @Test("a file whose times start again part way through is refused, read whole or sampled", arguments: [false, true])
    func timesThatStartAgainAreRefused(sampled: Bool) async throws {
        let part = try BridgeFixture.data("ts-h264.ts")
        let reader: any RandomAccessReading = sampled
            ? try PaddedRecording(transportStream: part + part, packetSize: 188, padding: .middleHalf(past: 270 << 20))
            : InMemoryRandomAccessReader(data: part + part)

        await #expect {
            _ = try await DeliveredFile.start(reading: reader, named: "clip.ts", clock: TestClock())
        } throws: {
            guard case Unplayable.refused(.timestampsRestart(let after)) = $0 else { return false }
            return (9...11).contains(after)
        }
    }

    // MARK: - Files sampled for their keyframes

    @Test("a transport stream sampled for its keyframes is cut at some of them, never at another picture, and its segments hold exactly the file's samples",
          arguments: [(name: "ts-h264.ts", packetSize: 188), ("m2ts-h264.m2ts", 192)])
    func sampledTransportStreamIsCutAtTrueKeyframes(name: String, packetSize: Int) async throws {
        let container = try #require(Self.containers.first { $0.name == name })
        try await Self.expectSampledFile(
            reading: PaddedRecording(transportStream: BridgeFixture.data(name), packetSize: packetSize, padding: .middleHalf(past: 270 << 20)),
            as: container)
    }

    @Test("a program stream sampled for its keyframes is cut at some of them, never at another picture, and its segments hold exactly the file's samples")
    func sampledProgramStreamIsCutAtTrueKeyframes() async throws {
        let container = try #require(Self.containers.first { $0.name == "numbered-h264.mpg" })
        try await Self.expectSampledFile(
            reading: PaddedRecording(programStream: BridgeFixture.data(container.name), padding: .middleHalf(past: 270 << 20)),
            as: container)
    }

    private static func expectSampledFile(reading padded: any RandomAccessReading, as container: Container) async throws {
        #expect(try await padded.fileSize > 256 << 20)
        let source = try Self.source(container.name)
        let file = try await DeliveredFile.start(reading: padded, named: container.name, clock: TestClock())
        let (segments, served) = try await Self.delivered(file) { file in
            (try await Self.segments("v", of: file),
             try await container.carried.asyncMap {
                try readBackSamples(of: try await file.rendition($0.rendition, fetchedIn: Order.descending.arranged), pathExtension: "mp4")
             })
        }

        #expect(segments.count >= 2)
        #expect(segments.allSatisfy { $0.first?.isKeyframe == true })
        for (carried, samples) in zip(container.carried, served) {
            Self.expect(samples, carrying: carried, of: source, in: container.name)
        }
    }

    /// Audio is read where its video is, so a segment's video and audio asked for at once want
    /// the same parts of the file while the first ask for them is still out. The stream is
    /// stretched to 150 MB, more than the delivery keeps, and read whole at open, so its start
    /// is read again.
    @Test("a segment's tracks asked for at once from a slow share read no part of the file twice")
    func segmentsAskedForAtOnceFromASlowShareReadEachPartOnce() async throws {
        let share = WatchedShare(try PaddedRecording(
            transportStream: BridgeFixture.data("ts-h264.ts"), packetSize: 188, padding: .middleHalf(past: 150 << 20)))
        let file = try await DeliveredFile.start(reading: share, named: "ts-h264.ts", support: Self.device)
        share.slowDown()
        try await Self.delivered(file) { file in
            // The segments in turn, so the parts of the file they share are still kept when the
            // next one asks.
            for index in try await file.segmentSeconds(of: "v.m3u8").indices {
                try await withThrowingTaskGroup(of: Void.self) { group in
                    for rendition in ["v", "a0", "a1"] { group.addTask { _ = try await file.bytes("\(rendition)-\(index).m4s") } }
                    try await group.waitForAll()
                }
            }
        }

        let asked = share.asked.sorted { $0.lowerBound < $1.lowerBound }
        #expect(asked.count > 8)
        #expect(zip(asked, asked.dropFirst()).filter { $0.overlaps($1) }.map { "\($0) and \($1)" } == [])
    }

    // MARK: - Playlists

    @Test("a stream's codec string names its sample entry and profile", arguments: [
        // The fixture's `hvcC` holds profile 1, compatibility flags 60000000, constraint byte
        // 90 and level 30.
        ("frame-numbers-hevc", "hvc1.1.6.L30.90,ac-3"),
        ("he-aac", "avc1.64000b,mp4a.40.5"),
        ("he-aac-v2", "avc1.64000b,mp4a.40.29"),
        ("flac", "avc1.64000b,fLaC"),
        ("eac3", "avc1.64000b,ec-3"),
        ("opus", "avc1.64000b,Opus"),
        // The fixture's `av1C` holds profile 0 (Main), level 0, the main tier and 8 bits.
        ("av1", "av01.0.00M.08,mp4a.40.2"),
        // The encodes of `h264-ffmpeg` and `frame-numbers-hevc`, whose profile and level a
        // transport stream holds in parameter sets behind start codes, not in a record. The
        // HEVC set's constraint bytes hold the `03` that keeps a start code out of them.
        ("ts-h264.ts", "avc1.640014,mp4a.40.2,ac-3"),
        ("ts-hevc-open-gop.ts", "hvc1.1.6.L30.90,ac-3"),
    ])
    func streamsReportTheirPlaylistCodec(name: String, codecs: String) async throws {
        let master = try await Self.delivered(try await DeliveredFile.start(name, support: Self.device)) { try await $0.master }

        #expect(master.contains(#"CODECS="\#(codecs)""#), "\(master)")
    }

    @Test("a Matroska file's playlists give its codecs, its picture's size and rate, and its length")
    func matroskaPlaylistsDescribeTheFile() async throws {
        let (master, video, audio) = try await Self.delivered(try await DeliveredFile.start("h264-mkvmerge")) { file in
            (try await file.master, try await file.segmentSeconds(of: "v.m3u8"), try await file.segmentSeconds(of: "a1.m3u8"))
        }

        #expect(master.contains(#"CODECS="avc1.640014,mp4a.40.2,ac-3",RESOLUTION=160x90,FRAME-RATE=24.000"#), "\(master)")
        // mkvmerge writes the file's length, 12.031 s.
        #expect(abs(video.reduce(0, +) - 12.031) < 0.001, "\(video)")
        #expect(abs(audio.reduce(0, +) - video.reduce(0, +)) < 0.001, "\(audio)")
    }

    /// A track with no title is named for its language in the viewer's own, which this does not
    /// pin.
    @Test("each audio track is listed with its language, its title, its channels and whether the file marks it as the default")
    func audioTracksCarryTheirTags() async throws {
        let master = try await Self.delivered(try await DeliveredFile.start("four-audio-tracks")) { try await $0.master }
        let tracks = master.split(separator: "\n").filter { $0.contains("TYPE=AUDIO") }

        #expect(tracks.map { Self.attribute("LANGUAGE", of: $0) } == ["eng", "jpn", "jpn", "ger"], "\(master)")
        #expect(Self.attribute("NAME", of: tracks[1]) == "Surround")
        #expect(tracks.map { Self.attribute("DEFAULT", of: $0) } == ["NO", "YES", "NO", "NO"])
        #expect(tracks.map { Self.attribute("CHANNELS", of: $0) } == ["2", "6", "2", "2"])
    }

    private static func attribute(_ name: String, of line: Substring) -> String? {
        guard let start = line.range(of: "\(name)=")?.upperBound else { return nil }
        let value = line[start...]
        return value.hasPrefix("\"") ? String(value.dropFirst().prefix { $0 != "\"" }) : String(value.prefix { $0 != "," })
    }
}

extension Array {
    fileprivate func asyncMap<T>(_ transform: (Element) async throws -> T) async rethrows -> [T] {
        var mapped: [T] = []
        for element in self { mapped.append(try await transform(element)) }
        return mapped
    }
}

/// A share that keeps every range asked of it and, once slowed down, forgets them and answers
/// each read 50 ms late.
private final class WatchedShare: RandomAccessReading {
    private let backing: any RandomAccessReading
    private let state = Mutex((slow: false, asked: [Range<UInt64>]()))

    init(_ backing: any RandomAccessReading) { self.backing = backing }

    var fileSize: UInt64 { get async throws { try await backing.fileSize } }

    var asked: [Range<UInt64>] { state.withLock { $0.asked } }

    func slowDown() { state.withLock { $0 = (slow: true, asked: []) } }

    func read(offset: UInt64, length: Int) async throws -> Data {
        let slow = state.withLock { state in
            state.asked.append(offset..<offset + UInt64(length))
            return state.slow
        }
        if slow { try await Task.sleep(for: .milliseconds(50)) }
        return try await backing.read(offset: offset, length: length)
    }
}
