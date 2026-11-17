import AVFoundation
import Foundation
import ParallaxCore
import Synchronization
import Testing
@testable import ParallaxPlayback

/// Video the bridge decodes and encodes again as HEVC, read back from its segments by Apple's
/// decoder. The fixtures' pictures carry their own frame numbers.
///
/// One case at a time: `copyNextSampleBuffer` blocks its thread.
@Suite("Converted video", .serialized)
struct ConvertedVideoTests {
    /// One picture of a segment.
    struct Picture: Equatable {
        /// The number the picture itself carries, on its middle row.
        let number: Int
        /// The number on the row above, which is the other field's row in a picture made of a
        /// field.
        let numberAbove: Int
        /// Ticks of the video timescale, as the fragment dates it.
        let tick: Int64
        let isKeyframe: Bool
    }

    private static func bytes(_ session: BridgeSession, _ path: String) async throws -> Data {
        try await #require(try await session.resource(at: path)).bytes()
    }

    /// The pictures of video segment `index` in the order they are shown, and how long Apple's
    /// reader says they last together.
    private static func pictures(
        of index: Int, in session: BridgeSession
    ) async throws -> (pictures: [Picture], seconds: Double) {
        // AVAssetReader reads one fragment of a fragmented file, so each segment is its own file.
        let file = try await bytes(session, "v-init.mp4") + bytes(session, "v-\(index).m4s")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).mp4")
        try file.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let asset = AVURLAsset(url: url)
        let video = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: video, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        ])
        reader.add(output)
        #expect(reader.startReading())
        var numbers: [(middle: Int, above: Int)] = []
        while let buffer = output.copyNextSampleBuffer() {
            let image = try #require(CMSampleBufferGetImageBuffer(buffer))
            numbers.append((BridgeFixture.frameNumber(in: image), BridgeFixture.frameNumber(in: image, rowsAboveTheMiddle: 1)))
        }
        let seconds = try await video.load(.timeRange).duration.seconds
        #expect(reader.status == .completed, "segment \(index): \(String(describing: reader.error))")
        // AVAssetReader starts every file at zero. libavformat reads where the fragment says
        // each sample is. The encoder writes pictures in the order they are shown.
        let samples = try readBackSamples(of: file, pathExtension: "mp4")
        #expect(samples.map(\.presentation) == samples.map(\.decode))
        #expect(samples.count == numbers.count)
        let pictures = zip(numbers, samples).map {
            Picture(number: $0.middle, numberAbove: $0.above, tick: $1.presentation, isKeyframe: $1.isKeyframe)
        }
        return (pictures, seconds)
    }

    @Test(
        "each segment of a converted video, asked for in any order, holds its own pictures at their own times and starts with a keyframe",
        arguments: [
            // AV1 in 10 bits, and MPEG-2 whose groups of pictures are all open, in a transport
            // stream.
            ("numbered-av1", "hvc1.2.4.L30.B0"), ("numbered-mpeg2-open-gop.ts", "hvc1.1.6.L30.B0"),
            ("numbered-vp9", "hvc1.1.6.L30.B0"), ("numbered-vp8", "hvc1.1.6.L30.B0"),
            ("numbered-mpeg4", "hvc1.1.6.L30.B0"), ("numbered-wmv2", "hvc1.1.6.L30.B0"),
            // 10-bit H.264 on a device with no decoder for it, and 4:2:2, which no device has.
            ("numbered-h264-high10", "hvc1.2.4.L30.B0"), ("numbered-h264-422", "hvc1.1.6.L30.B0"),
            ("numbered-flv1.flv", "hvc1.1.6.L30.B0"), ("numbered-mpeg4.avi", "hvc1.1.6.L30.B0"),
        ])
    func segmentsHoldTheirOwnPictures(name: String, codec: String) async throws {
        let session = try await BridgeSession.open(
            InMemoryRandomAccessReader(data: BridgeFixture.data(name)), support: BridgeFixture.fewestDecoders,
            showsHDR: true)
        let segments = session.plan.video.segments
        #expect(session.plan.video.rendition.codec == codec)

        var read: [Int: (pictures: [Picture], seconds: Double)] = [:]
        for index in segments.indices.shuffled() { read[index] = try await Self.pictures(of: index, in: session) }
        let inOrder = try segments.indices.map { try #require(read[$0]) }
        let all = inOrder.flatMap(\.pictures)

        // 24 pictures a second on a clock of 120,000 ticks.
        let first = try #require(all.first)
        #expect(all.map(\.number) == Array(0..<all.count))
        // The clips are twelve seconds long, or a minute.
        #expect([288, 1440].contains(all.count), "\(all.count)")
        #expect(all.map { $0.tick - first.tick } == all.indices.map { Int64($0) * 5000 })
        for (segment, made) in zip(segments, inOrder) {
            #expect(made.pictures.first?.isKeyframe == true)
            // A picture marked a keyframe that is not one is where a seek would start decoding.
            #expect(made.pictures.dropFirst().contains { !$0.isKeyframe })
            // The last picture lasts until the next segment's first.
            #expect(abs(made.seconds - segment.seconds) < 0.0001, "\(made.seconds) for \(segment.seconds)")
        }
        // The report has each segment's speed.
        #expect(session.conversions.all.count == segments.count)
    }

    @Test(
        "video stored as fields plays as a picture for each field, at twice the frame rate, whatever its codec",
        arguments: ["numbered-interlaced-mpeg2.ts", "numbered-interlaced-h264.ts"])
    func fieldsBecomePictures(name: String) async throws {
        // A device that decodes H.264 still shows its fields combed.
        let session = try await BridgeSession.open(
            InMemoryRandomAccessReader(data: BridgeFixture.data(name)), support: BridgeFixture.fewestDecoders,
            showsHDR: true)
        let segments = session.plan.video.segments
        #expect(session.plan.video.rendition.codec == "hvc1.1.6.L60.B0")
        #expect(HLSPlaylist.master(for: session.plan).contains("FRAME-RATE=50.000"))

        var read: [Int: (pictures: [Picture], seconds: Double)] = [:]
        for index in segments.indices.shuffled() { read[index] = try await Self.pictures(of: index, in: session) }
        let inOrder = try segments.indices.map { try #require(read[$0]) }
        let all = inOrder.flatMap(\.pictures)

        // Twelve seconds of 25 frames a second, each two fields. The top field is the even
        // rows, and the middle row is one of them.
        let first = try #require(all.first)
        #expect(all.count == 600)
        #expect(all.enumerated().map { $0.offset.isMultiple(of: 2) ? $0.element.number : $0.element.numberAbove } == Array(0..<all.count))
        #expect(all.map { $0.tick - first.tick } == all.indices.map { Int64($0) * 2400 })
        for (segment, made) in zip(segments, inOrder) {
            #expect(made.pictures.first?.isKeyframe == true)
            #expect(abs(made.seconds - segment.seconds) < 0.0001, "\(made.seconds) for \(segment.seconds)")
        }
    }

    @Test("a file whose video has to be converted is refused by name on a device with no HEVC encoder")
    func noEncoderRefusesTheFile() async throws {
        let demuxer = try await BridgeFixture.demuxer("numbered-vp9")

        await #expect(throws: BridgeRefusal.videoEncoder(name: "vp9 Profile 0")) {
            _ = try await BridgePlan(reading: demuxer, support: BridgeFixture.fewestDecoders, showsHDR: true) { _ in
                throw HEVCEncoder.Failure.session(code: -12908)
            }
        }
        #expect("\(BridgeRefusal.videoEncoder(name: "vp9 Profile 0"))" == "video: vp9 Profile 0, and this device has no HEVC encoder")
    }

    @Test("a segment whose damaged stream decodes a picture timed before one it already gave still arrives, its pictures in order")
    func damagedStreamKeepsItsOrder() async throws {
        let whole = try BridgeFixture.data("numbered-mpeg2-open-gop.ts")
        // Inside a picture of the second segment.
        let damaged = whole.enumerated().reduce(into: whole) { data, byte in
            if (65100..<65230).contains(byte.offset) { data[byte.offset] = 0xA5 }
        }
        func ticks(of data: Data) async throws -> [[Int64]] {
            let session = try await BridgeSession.open(
                InMemoryRandomAccessReader(data: data), support: BridgeFixture.fewestDecoders, showsHDR: true)
            var read: [[Int64]] = []
            for index in 0..<4 {
                let file = try await Self.bytes(session, "v-init.mp4") + Self.bytes(session, "v-\(index).m4s")
                read.append(try readBackSamples(of: file, pathExtension: "mp4").map(\.presentation))
            }
            return read
        }

        let expected = try await ticks(of: whole)
        let made = try await ticks(of: damaged)

        #expect(!made[1].isEmpty)
        #expect(made[1] == made[1].sorted())
        #expect(Set(made[1]).isSubset(of: Set(expected[1])))
        // A segment is decoded from its own keyframe, so the damage stays in the one.
        #expect(made[2...] == expected[2...])
    }

    @Test("work asked of the one-at-a-time gate together runs one piece after another")
    func workTakesTurns() async {
        let turns = OneAtATime()
        let running = Mutex((now: 0, most: 0))

        await withTaskGroup { group in
            for _ in 0..<8 {
                group.addTask {
                    await turns.run {
                        running.withLock {
                            $0.now += 1
                            $0.most = max($0.most, $0.now)
                        }
                        for _ in 0..<10 { await Task.yield() }
                        running.withLock { $0.now -= 1 }
                    }
                }
            }
        }

        #expect(running.withLock { $0.most } == 1)
    }
}
