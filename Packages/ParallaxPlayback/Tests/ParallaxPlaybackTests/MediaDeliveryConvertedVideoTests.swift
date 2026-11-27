import AVFoundation
import Foundation
import Testing
import ParallaxCore
import ParallaxPlayback

/// Video a delivery converts to HEVC on a device with the fewest decoders, fetched over HTTP and
/// read back by Apple's decoder. The fixtures' pictures carry their own frame numbers.
///
/// One case at a time: `copyNextSampleBuffer` blocks its thread.
@Suite("MediaDelivery — converted video", .serialized, .timeLimit(.minutes(1)))
struct MediaDeliveryConvertedVideoTests {
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

    /// One video segment as fetched: its pictures in the order they are shown, how long Apple's
    /// reader says they last together, and how long the playlist says the segment is.
    struct Segment {
        let pictures: [Picture]
        let seconds: Double
        let listedSeconds: Double
    }

    /// The video codec the master playlist names, its first `CODECS` entry.
    private static func videoCodec(in master: String) -> String? {
        master.firstMatch(of: /CODECS="([^,"]+)/).map { String($0.1) }
    }

    /// Every video segment of a delivery, fetched in `order`, in the rendition's order, and the
    /// master playlist.
    private static func segments(
        of file: DeliveredFile, order: (Range<Int>) -> [Int] = { $0.shuffled() }
    ) async throws -> (segments: [Segment], master: String) {
        let master = try await file.master
        let listed = try await file.segmentSeconds(of: "v.m3u8")
        let initSegment = try await file.bytes("v-init.mp4")
        var read: [Int: Segment] = [:]
        for index in order(listed.indices) {
            let (pictures, seconds) = try await Self.pictures(in: initSegment + file.bytes("v-\(index).m4s"), index: index)
            read[index] = Segment(pictures: pictures, seconds: seconds, listedSeconds: listed[index])
        }
        return (try listed.indices.map { try #require(read[$0]) }, master)
    }

    private static func delivered(
        _ name: String, reading data: Data? = nil, order: (Range<Int>) -> [Int] = { $0.shuffled() }
    ) async throws -> (segments: [Segment], master: String) {
        let file = try await DeliveredFile.start(
            reading: InMemoryRandomAccessReader(data: try data ?? BridgeFixture.data(name)), named: name,
            support: BridgeFixture.fewestDecoders)
        do {
            let read = try await segments(of: file, order: order)
            await file.stop()
            return read
        } catch {
            await file.stop()
            throw error
        }
    }

    /// AVAssetReader reads one fragment of a fragmented file, so each segment is its own file.
    private static func pictures(in file: Data, index: Int) async throws -> (pictures: [Picture], seconds: Double) {
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
            ("numbered-wmv2.asf", "hvc1.1.6.L30.B0"),
            // MPEG-4 with B-pictures, in containers that store decode times only.
            ("numbered-mpeg4-b.avi", "hvc1.1.6.L30.B0"), ("numbered-mpeg4-b.asf", "hvc1.1.6.L30.B0"),
            // MPEG-2 in a program stream. In the second, a read after a seek gives one keyframe
            // no presentation time.
            ("numbered-mpeg2.mpg", "hvc1.1.6.L30.B0"), ("numbered-mpeg2-mp2.mpg", "hvc1.1.6.L30.B0"),
            // H.264 the device decodes, which is copied out of any other container.
            ("numbered-h264.mpg", "hvc1.1.6.L30.B0"),
        ])
    func segmentsHoldTheirOwnPictures(name: String, codec: String) async throws {
        let (segments, master) = try await Self.delivered(name)
        let all = segments.flatMap(\.pictures)

        #expect(Self.videoCodec(in: master) == codec, "\(master)")
        // 24 pictures a second on a clock of 120,000 ticks.
        let first = try #require(all.first)
        #expect(all.map(\.number) == Array(0..<all.count))
        // The clips are twelve or sixteen seconds long, or a minute.
        #expect([288, 384, 1440].contains(all.count), "\(all.count)")
        #expect(all.map { $0.tick - first.tick } == all.indices.map { Int64($0) * 5000 })
        for segment in segments {
            #expect(segment.pictures.first?.isKeyframe == true)
            // A picture marked a keyframe that is not one is where a seek would start decoding.
            #expect(segment.pictures.dropFirst().contains { !$0.isKeyframe })
            // The last picture lasts until the next segment's first. The playlist lists a
            // length to the microsecond.
            #expect(abs(segment.seconds - segment.listedSeconds) < 0.0001, "\(segment.seconds) for \(segment.listedSeconds)")
        }
    }

    @Test(
        "video stored as fields plays as a picture for each field, at twice the frame rate, whatever its codec",
        arguments: ["numbered-interlaced-mpeg2.ts", "numbered-interlaced-h264.ts"])
    func fieldsBecomePictures(name: String) async throws {
        // A device that decodes H.264 still shows its fields combed.
        let (segments, master) = try await Self.delivered(name)
        let all = segments.flatMap(\.pictures)

        #expect(Self.videoCodec(in: master) == "hvc1.1.6.L60.B0", "\(master)")
        #expect(master.contains("FRAME-RATE=50.000"))
        // Twelve seconds of 25 frames a second, each two fields. The top field is the even
        // rows, and the middle row is one of them.
        let first = try #require(all.first)
        #expect(all.count == 600)
        #expect(all.enumerated().map { $0.offset.isMultiple(of: 2) ? $0.element.number : $0.element.numberAbove } == Array(0..<all.count))
        #expect(all.map { $0.tick - first.tick } == all.indices.map { Int64($0) * 2400 })
        for segment in segments {
            #expect(segment.pictures.first?.isKeyframe == true)
            #expect(abs(segment.seconds - segment.listedSeconds) < 0.0001, "\(segment.seconds) for \(segment.listedSeconds)")
        }
    }

    @Test("a segment whose damaged stream decodes a picture timed before one it already gave still arrives, its pictures in order")
    func damagedStreamKeepsItsOrder() async throws {
        let name = "numbered-mpeg2-open-gop.ts"
        let whole = try BridgeFixture.data(name)
        // Inside a picture of the second segment.
        let damaged = whole.enumerated().reduce(into: whole) { data, byte in
            if (65100..<65230).contains(byte.offset) { data[byte.offset] = 0xA5 }
        }
        func ticks(of data: Data) async throws -> [[Int64]] {
            let file = try await DeliveredFile.start(
                reading: InMemoryRandomAccessReader(data: data), named: name, support: BridgeFixture.fewestDecoders)
            do {
                var read: [[Int64]] = []
                for index in 0..<4 {
                    let bytes = try await file.bytes("v-init.mp4") + file.bytes("v-\(index).m4s")
                    read.append(try readBackSamples(of: bytes, pathExtension: "mp4").map(\.presentation))
                }
                await file.stop()
                return read
            } catch {
                await file.stop()
                throw error
            }
        }

        let expected = try await ticks(of: whole)
        let made = try await ticks(of: damaged)

        #expect(made[1] == made[1].sorted())
        #expect(Set(made[1]).isSubset(of: Set(expected[1])))
        // The whole segment arrives: it ends where the undamaged one does.
        #expect(made[1].last == expected[1].last, "\(made[1].count) of \(expected[1].count) pictures")
        // A segment is decoded from its own keyframe, so the damage stays in the one.
        #expect(made[2...] == expected[2...])
    }

    /// A hardware encoder opens only a few sessions at once, and AVPlayer asks for segments
    /// while others are still being made. Two encodes of one segment can differ in a byte or
    /// two, so the segments are compared by the pictures they show.
    @Test("converted segments asked for all at once are the ones asked for one by one")
    func convertedSegmentsAskedForAtOnceMatchOneByOne() async throws {
        let name = "numbered-vp9"
        let oneByOne = try await DeliveredFile.start(name, support: BridgeFixture.fewestDecoders)
        let expected = try await Self.segments(of: oneByOne, order: Array.init).segments.map(\.pictures)
        let initSegment = try await oneByOne.bytes("v-init.mp4")
        await oneByOne.stop()

        let file = try await DeliveredFile.start(name, support: BridgeFixture.fewestDecoders)
        let atOnce = try await withThrowingTaskGroup(of: (Int, Data).self) { group in
            for index in expected.indices { group.addTask { (index, try await file.bytes("v-\(index).m4s")) } }
            return try await group.reduce(into: [:]) { $0[$1.0] = $1.1 }
        }
        await file.stop()
        var shown: [[Picture]] = []
        for index in expected.indices {
            shown.append(try await Self.pictures(in: initSegment + (try #require(atOnce[index])), index: index).pictures)
        }

        #expect(expected.count > 1)
        #expect(shown == expected)
    }
}
