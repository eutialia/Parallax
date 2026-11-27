import AVFoundation
import Foundation
import Synchronization
import Testing
import ParallaxCore
import ParallaxTestScaling
import ParallaxPlayback

/// The segments a bridged delivery serves, fetched over HTTP and read back by libavformat's own
/// demuxer.
@Suite("MediaDelivery — the segments it serves", .scaledTimeLimit())
struct MediaDeliverySegmentTests {

    /// The samples of `rendition`, fetched from a delivery of `name` in `order`.
    private static func readBack(
        _ name: String, _ rendition: String, fetchedIn order: @escaping (Range<Int>) -> [Int] = { $0.shuffled() }
    ) async throws -> [ReadbackSample] {
        let file = try await DeliveredFile.start(name)
        do {
            let bytes = try await file.rendition(rendition, fetchedIn: order)
            await file.stop()
            return try readBackSamples(of: bytes, pathExtension: "mp4")
        } catch {
            await file.stop()
            throw error
        }
    }

    @Test(
        "a rendition's segments, asked for out of order, hold every source sample once, on one timeline with the other rendition",
        arguments: [("v", 0, Int64(12_520), Int64(5000)), ("a0", 1, 4000, 1024)])
    func segmentsHoldEverySourceSampleOnOneTimeline(
        rendition: String, stream: Int, first: Int64, step: Int64
    ) async throws {
        let readBack = try await Self.readBack("h264-mkvmerge", rendition)
        let source = try BridgeFixture.sourcePackets("h264-mkvmerge", stream: stream)

        #expect(readBack.map { BridgeFixture.SourcePacket(md5: $0.md5, isKeyframe: $0.isKeyframe) } == source)
        // Video starts at 104.33 ms (12,520 of 120,000) and audio 21.0 ms before it, at 83.33 ms
        // (4,000 of 48,000): the source's own offset between the two.
        #expect(readBack.map(\.presentation).sorted() == source.indices.map { first + Int64($0) * step })
    }

    /// A transport stream stores H.264 behind start codes and AAC behind ADTS headers, and an
    /// MP4 sample holds neither. The fixture is `h264-ffmpeg`'s encode in a transport stream,
    /// so its audio comes back as that file's own packets. Its video holds the parameter sets
    /// and delimiters a transport stream puts in each picture, so it is counted and timed, and
    /// AVPlayer's cases show its pictures.
    @Test("a transport stream's segments, asked for out of order, hold every source sample once, in the form an MP4 holds it")
    func transportStreamSegmentsHoldEverySourceSample() async throws {
        let video = try await Self.readBack("ts-h264.ts", "v")
        let aac = try await Self.readBack("ts-h264.ts", "a0")
        let ac3 = try await Self.readBack("ts-h264.ts", "a1")

        #expect(video.map(\.isKeyframe) == (try BridgeFixture.sourcePackets("ts-h264.ts", stream: 0).map(\.isKeyframe)))
        // The first picture shows at 1.4833 s: 178,000 of 120,000. Then one every 5,000.
        #expect(video.map(\.presentation).sorted() == (0..<288).map { 178_000 + Int64($0) * 5000 })
        #expect(aac.map(\.md5) == (try BridgeFixture.sourcePackets("h264-ffmpeg", stream: 1).map(\.md5)))
        // The audio starts at 1.462 s: 70,176 of 48,000.
        #expect(aac.map(\.presentation) == (0..<564).map { 70_176 + Int64($0) * 1024 })
        #expect(ac3.map(\.md5) == (try BridgeFixture.sourcePackets("h264-ffmpeg", stream: 2).map(\.md5)))
    }

    /// FLV holds H.264 and AAC as an MP4 does, so both come back as the file's own packets. An
    /// AVI holds H.264 behind start codes, which is counted and timed, and its AC-3 comes back
    /// as stored. The AVI's packets carry no presentation time. An ASF holds the same as the
    /// AVI, timed in whole milliseconds.
    @Test("an FLV's, an AVI's and an ASF's segments, asked for out of order, hold every source sample once, evenly spaced",
          arguments: [
            ("flv-h264.flv", true, Int64(1024)), ("avi-h264.avi", false, 1536), ("asf-h264.asf", false, 1536),
          ])
    func segmentsHoldEverySourceSample(name: String, videoIsInMP4Form: Bool, audioFrameLength: Int64) async throws {
        let video = try await Self.readBack(name, "v")
        let audio = try await Self.readBack(name, "a0")
        let sourceVideo = try BridgeFixture.sourcePackets(name, stream: 0)
        let firstPicture = try #require(video.map(\.presentation).min())
        let firstFrame = try #require(audio.first?.presentation)

        #expect(video.map(\.isKeyframe) == sourceVideo.map(\.isKeyframe))
        if videoIsInMP4Form { #expect(video.map(\.md5) == sourceVideo.map(\.md5)) }
        // 24 pictures a second: one every 5,000 of 120,000.
        #expect(video.map(\.presentation).sorted() == (0..<288).map { firstPicture + Int64($0) * 5000 })
        #expect(audio.map(\.md5) == (try BridgeFixture.sourcePackets(name, stream: 1).map(\.md5)))
        #expect(audio.map(\.presentation) == audio.indices.map { firstFrame + Int64($0) * audioFrameLength })
    }

    /// The fixture is two four-second parts, joined as a downloaded stream's are: 184 frames of
    /// audio, a hole, and 184 more that start four seconds after the first, which is 187 and
    /// a half frames.
    @Test("audio that goes on half a frame off after a hole keeps every frame at its own time")
    func audioAfterAHoleKeepsItsOwnTimes() async throws {
        let readBack = try await Self.readBack("ts-audio-gap.ts", "a0", fetchedIn: Array.init).map(\.presentation)
        let first = try #require(readBack.first)

        let firstPart: [Int64] = (0..<184).map { $0 * 1024 }
        let secondPart: [Int64] = (0..<184).map { 192_000 + $0 * 1024 }
        #expect(readBack.map { $0 - first } == firstPart + secondPart)
    }

    @Test("AAC at 44.1 kHz, which a transport stream times to the nearest tick, plays a frame after a frame")
    func audioTimedToTheNearestTickIsEvenlySpaced() async throws {
        let readBack = try await Self.readBack("ts-aac-44100.ts", "a0", fetchedIn: Array.init).map(\.presentation)

        #expect(readBack.count > 170)
        #expect(zip(readBack.dropFirst(), readBack).allSatisfy { $0 - $1 == 1024 })
    }

    /// An MP4 sample of E-AC-3 holds six blocks, so the muxer joins frames of three into pairs,
    /// and libavformat's demuxer splits them again on reading. The fixture's 375 frames fall 125
    /// to a two-second segment, and the last has no partner.
    @Test("an E-AC-3 rendition of three-block frames holds every frame but an unpaired last one, evenly spaced")
    func shortEAC3FramesArePairedAcrossSegments() async throws {
        let readBack = try await Self.readBack("eac3-three-blocks", "a0", fetchedIn: Array.init)
        let first = try #require(readBack.first?.presentation)

        #expect(readBack.count == 374)
        #expect(readBack.map(\.presentation) == readBack.indices.map { first + Int64($0) * 768 })
    }

    /// Frames of one block, six to an MP4 sample, as a short-frame encoder writes them. The
    /// fixture's 375 frames make 62 samples and three left over. Its video has no B-frames, so
    /// the file's opening reads one picture and no more audio than it asks for.
    @Test("an E-AC-3 rendition of one-block frames holds every frame but an unfinished last sample's, evenly spaced")
    func oneBlockEAC3FramesAreJoinedInSixes() async throws {
        let readBack = try await Self.readBack("eac3-one-block", "a0", fetchedIn: Array.init)
        let first = try #require(readBack.first?.presentation)

        #expect(readBack.count == 372)
        #expect(readBack.map(\.presentation) == readBack.indices.map { first + Int64($0) * 256 })
    }

    /// The fixture's 126 frames end on a pair that starts before the segment boundary at 2 s and
    /// ends after it, so the track's audio ends in the first segment.
    @Test("an E-AC-3 track of three-block frames that ends on a pair across a segment boundary lists only segments that build")
    func shortEAC3PairAcrossTheLastBoundary() async throws {
        let file = try await DeliveredFile.start("eac3-three-blocks-ends-early")
        let segments = try await file.segmentSeconds(of: "a0.m3u8")
        let bytes = try await file.rendition("a0", fetchedIn: Array.init)
        await file.stop()

        let readBack = try readBackSamples(of: bytes, pathExtension: "mp4")
        let first = try #require(readBack.first?.presentation)

        #expect(segments.count == 1)
        #expect(readBack.count == 126)
        #expect(readBack.map(\.presentation) == readBack.indices.map { first + Int64($0) * 768 })
    }

    /// The fixture's header declares 23.976 frames a second. Its first two seconds run at 59.94.
    @Test("video faster than its declared rate keeps each frame at its own time")
    func videoFasterThanDeclaredKeepsItsTimes() async throws {
        let readBack = try await Self.readBack("rate-above-declared", "v", fetchedIn: Array.init)
            .map { Double($0.presentation) / Double($0.timescale) }.sorted()
        let source = try readBackSamples(of: BridgeFixture.data("rate-above-declared"), pathExtension: "mkv")
            .filter { $0.stream == 0 }.map { Double($0.presentation) / Double($0.timescale) }.sorted()
        let offsets = zip(readBack, source).map { $0 - $1 }

        #expect(readBack.count == source.count)
        // A millisecond: the container's tick.
        #expect((offsets.max() ?? 0) - (offsets.min() ?? 0) <= 0.001)
    }

    /// A copied segment's last picture has no next one in its segment to last until. At 24 a
    /// second it lasts one step of the rate; at 7, which no whole number of ticks spaces, it
    /// lasts as long as its packet says. Each segment is read back on its own, where that
    /// picture is the last one.
    @Test("the last picture of each copied video segment lasts as long as the file says it does",
          arguments: ["h264-mkvmerge", "odd-rate-h264"])
    func lastPictureOfACopiedSegmentLastsItsOwnLength(name: String) async throws {
        let source = try readBackSamples(of: BridgeFixture.data(name), pathExtension: "mkv").filter { $0.stream == 0 }
        let lengths = Dictionary(source.map { ($0.md5, Double($0.duration) / Double($0.timescale)) }) { first, _ in first }
        let file = try await DeliveredFile.start(name)
        let lasts = try await MediaDeliveryContainerTests.segments("v", of: file).compactMap(\.last)
        await file.stop()

        #expect(lasts.count > 1)
        for last in lasts {
            let length = Double(last.duration) / Double(last.timescale)
            let stored = try #require(lengths[last.md5])
            #expect(stored > 0 && abs(length - stored) < 0.001, "\(length) s for a picture of \(stored) s at \(last.presentation)")
        }
    }

    /// AVPlayer keeps playing video over audio it cannot decode and reports nothing, so the
    /// frame cases cannot vouch for audio. This one hands the rendition to Apple's decoder
    /// directly. Every fixture's audio is a tone, at an eighth of full scale.
    ///
    /// One case at a time: `copyNextSampleBuffer` blocks its thread, and ten cases at once hold
    /// every thread the readers' own work needs.
    @Test("Apple's decoder turns each audio rendition back into its source's tone, for its whole length", .serialized, arguments: [
        ("h264-mkvmerge", "a0", 440.0, 6, 12.0), ("h264-mkvmerge", "a1", 440, 6, 12),
        ("frame-numbers-hevc", "a0", 440, 30, 60), ("he-aac", "a0", 440, 2, 4), ("he-aac-v2", "a0", 440, 2, 4),
        ("flac", "a0", 440, 2, 4), ("eac3", "a0", 440, 2, 4), ("opus", "a0", 440, 2, 4),
        // AAC, AC-3 in 5.1, DTS converted to FLAC, and FLAC.
        ("four-audio-tracks", "a0", 440, 3, 6), ("four-audio-tracks", "a1", 880, 3, 6),
        ("four-audio-tracks", "a2", 440, 3, 6), ("four-audio-tracks", "a3", 660, 3, 6),
        // AAC behind ADTS headers, and AC-3.
        ("ts-h264.ts", "a0", 440, 6, 12), ("ts-h264.ts", "a1", 440, 6, 12),
        // ALAC is copied. The five after it are converted to FLAC.
        ("alac", "a0", 440, 2, 4), ("mp3", "a0", 440, 2, 4), ("mp2", "a0", 440, 2, 4), ("vorbis", "a0", 440, 2, 4),
        ("wma", "a0", 440, 2, 4), ("ld-aac", "a0", 440, 1, 2),
        // AAC as an FLV holds it, and AC-3 timed by an AVI's count of frames.
        ("flv-h264.flv", "a0", 440, 6, 12), ("avi-h264.avi", "a0", 440, 6, 12),
        // WMA converted to FLAC, timed by an ASF's packets in whole milliseconds. Its first
        // picture is at 43 ms, and its audio is delivered from there.
        ("numbered-wmv2.asf", "a0", 440, 5, 12.04),
        // AC-3 copied out of a program stream, where some frames carry the time of the frame after them.
        ("numbered-mpeg2.mpg", "a0", 440, 6, 12),
        // Copied AAC, AAC behind ADTS headers, E-AC-3 and AC-3 that start 0.3 s after the first
        // picture, led in by silence in their own codec from before it. The AC-3 family's first
        // frame is at 294.7 ms, and ten frames of 32 ms start 25 ms before the picture.
        ("numbered-h264-late-aac", "a0", 440, 6, 12), ("numbered-h264-late-aac.ts", "a0", 440, 6, 12),
        ("numbered-h264-late-eac3", "a0", 440, 6, 12.025), ("numbered-h264-late-ac3.mpg", "a0", 440, 6, 12.025),
    ])
    func audioRenditionDecodesToTheSourceTone(
        name: String, rendition: String, hertz: Double, segmentCount: Int, seconds: Double
    ) async throws {
        let file = try await DeliveredFile.start(name)
        let initSegment: Data
        var segmentBytes: [Data] = []
        do {
            #expect(try await file.segmentSeconds(of: "\(rendition).m3u8").count == segmentCount)
            initSegment = try await file.bytes("\(rendition)-init.mp4")
            for index in 0..<segmentCount { segmentBytes.append(try await file.bytes("\(rendition)-\(index).m4s")) }
            await file.stop()
        } catch {
            await file.stop()
            throw error
        }
        var segments: [[Int16]] = []
        for bytes in segmentBytes { segments.append(try await Self.decoded(initSegment + bytes)) }

        let decodedSeconds = Double(segments.joined().count) / 48_000
        // Decoding a segment on its own drops the decoder's start-up samples from each: up to
        // 40 ms for AAC. The last frame of a FLAC or Opus track holds fewer samples than the
        // rest and decodes at its full length: up to 20 ms over.
        #expect((-0.02...0.04 * Double(segmentCount)).contains(seconds - decodedSeconds), "\(decodedSeconds) s")
        // A tenth of a second holds whole cycles of each tone (44, 66 or 88), so the part of a window that
        // is the tone is its projection onto one sine and one cosine. A segment's first window
        // is left out: it holds the decoder settling.
        let window = 4800
        let shares = segments.flatMap { samples in
            stride(from: window, to: samples.count - window, by: window).map { samples[$0..<$0 + window] }
        }.map { samples -> Double in
            let slice = samples.map(Double.init)
            let phase = slice.indices.map { 2 * Double.pi * hertz * Double($0) / 48_000 }
            let sine = zip(slice, phase).reduce(0) { $0 + $1.0 * sin($1.1) }
            let cosine = zip(slice, phase).reduce(0) { $0 + $1.0 * cos($1.1) }
            let total = slice.reduce(0) { $0 + $1 * $1 }
            return total > 0 ? (sine * sine + cosine * cosine) * 2 / Double(window) / total : 0
        }
        let toneWindows = shares.count { $0 > 0.9 }
        #expect(Double(toneWindows) > 0.95 * Double(shares.count), "\(toneWindows) of \(shares.count) windows are the tone")
    }

    /// An audio segment as Apple's decoder plays it, in 16-bit mono at 48 kHz.
    /// AVAssetReader reads one fragment of a fragmented file, so each segment is its own file.
    private static func decoded(_ segment: Data) async throws -> [Int16] {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).mp4")
        try segment.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let asset = AVURLAsset(url: url)
        let track = try #require(try await asset.loadTracks(withMediaType: .audio).first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false, AVNumberOfChannelsKey: 1,
            AVSampleRateKey: 48_000,
        ])
        reader.add(output)
        #expect(reader.startReading())
        var samples: [Int16] = []
        while let buffer = output.copyNextSampleBuffer() {
            let block = try #require(CMSampleBufferGetDataBuffer(buffer))
            var chunk = [Int16](repeating: 0, count: CMBlockBufferGetDataLength(block) / 2)
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: chunk.count * 2, destination: &chunk)
            samples += chunk
        }
        #expect(reader.status == .completed, "\(String(describing: reader.error))")
        return samples
    }

    /// Each fixture is the numbered picture over silence, with a 10 ms burst of 1 kHz centred
    /// on pictures 60 and 204, where ffmpeg's decode of the source puts both to within 0.3 ms.
    /// Converted audio is FLAC, which decodes from a segment's first sample with nothing
    /// dropped, so a segment's samples start at its first sample's time.
    @Test("converted audio keeps its place against the video: a burst made on a numbered picture plays within 5 ms of it",
          .serialized, arguments: ["numbered-clicks-wmv2.asf", "numbered-clicks-wma.mkv", "numbered-clicks-mp3.mkv"])
    func convertedAudioKeepsItsPlace(name: String) async throws {
        let file = try await DeliveredFile.start(name)
        let video: Data, audioInit: Data
        var audioSegments: [Data] = []
        do {
            video = try await file.rendition("v", fetchedIn: Array.init)
            audioInit = try await file.bytes("a0-init.mp4")
            for index in try await file.segmentSeconds(of: "a0.m3u8").indices {
                audioSegments.append(try await file.bytes("a0-\(index).m4s"))
            }
            await file.stop()
        } catch {
            await file.stop()
            throw error
        }
        let pictures = try readBackSamples(of: video, pathExtension: "mp4")
            .map { Double($0.presentation) / Double($0.timescale) }.sorted()
        try #require(pictures.count == 288, "\(pictures.count) pictures")
        var heard: [(seconds: Double, level: Double)] = []
        for segment in audioSegments {
            let first = try #require(try readBackSamples(of: audioInit + segment, pathExtension: "mp4").first)
            let start = Double(first.presentation) / Double(first.timescale)
            let samples = try await Self.decoded(audioInit + segment)
            heard += samples.enumerated().map { (start + Double($0.offset) / 48_000, Double($0.element) * Double($0.element)) }
        }

        for picture in [60, 204] {
            let shown = pictures[picture]
            let near = heard.filter { abs($0.seconds - shown) < 0.2 }
            let energy = near.reduce(0) { $0 + $1.level }
            try #require(energy > 0, "no burst within 0.2 s of picture \(picture)")
            let burst = near.reduce(0) { $0 + $1.seconds * $1.level } / energy
            #expect(abs(burst - shown) < 0.005,
                    "picture \(picture) is at \(shown) s and its burst at \(burst) s, \(Int(((burst - shown) * 1000).rounded())) ms off")
        }
    }

    @Test("a path the delivery does not have is not found", arguments: [
        "v-6.m4s", "v-007.m4s", "v--1.m4s", "x-0.m4s", "v.mp4", "master", "a0-init.m4s", "a-0.m4s", "a00-0.m4s", "a2-0.m4s", "",
    ])
    func unknownPathIsNotFound(path: String) async throws {
        let file = try await DeliveredFile.start("h264-mkvmerge")
        let (_, response) = try await ephemeralHTTPSession().data(from: file.url(of: path))
        await file.stop()

        #expect((response as? HTTPURLResponse)?.statusCode == 404)
    }

    /// Nine of the fixture's frames start in one PES packet and end in the next, and libavformat
    /// gives each the time of the frame after it.
    @Test("AC-3 in an MPG or VOB is copied, and its segments, asked for in any order, hold every frame once")
    func ac3InProgramStreamIsCopied() async throws {
        let name = "numbered-h264-ac3.mpg"
        let file = try await DeliveredFile.start(name)
        let master = try await file.master
        let bytes = try await file.rendition("a0")
        await file.stop()
        let frames = try readBackSamples(of: bytes, pathExtension: "mp4")
        let first = try #require(frames.first?.presentation)

        #expect(master.contains(#",ac-3""#), "\(master)")
        #expect(frames.map(\.md5) == (try BridgeFixture.sourcePackets(name, stream: 1).map(\.md5)))
        // 1,536 samples a frame at 48 kHz.
        #expect(frames.map(\.presentation) == frames.indices.map { first + Int64($0) * 1536 })
    }

    /// The second audio stream plays from 20 s to 24 s only: libavformat finds it neither in
    /// what it reads to describe the file nor in what it reads of the end, as a DVD's
    /// subtitles are.
    @Test("an MPG with a stream that first appears partway through is delivered without that stream, every segment of it")
    func streamFirstSeenPartwayThroughIsLeftOut() async throws {
        let file = try await DeliveredFile.start("numbered-h264-late-audio.mpg")
        let master = try await file.master
        _ = try await file.rendition("v")
        _ = try await file.rendition("a0")
        let secondTrack = try await ephemeralHTTPSession().data(from: file.url(of: "a1.m3u8")).1
        await file.stop()

        #expect(master.components(separatedBy: "TYPE=AUDIO").count == 2, "\(master)")
        #expect(master.contains(#",ac-3""#))
        #expect((secondTrack as? HTTPURLResponse)?.statusCode == 404)
    }

    /// The first look at a file, which tells its format, is 389 bytes read before the bridge
    /// opens: enough to see three M2TS sync bytes.
    private static let formatLook = 389

    @Test("serving every segment of every track reads no part of the file twice but its first look, and in few requests")
    func eachPartOfTheFileIsReadOnce() async throws {
        let data = try BridgeFixture.data("four-audio-tracks")
        let reader = CountingReader(data)
        let file = try await DeliveredFile.start(reading: reader, named: "four-audio-tracks.mkv")
        for rendition in ["v", "a0", "a1", "a2", "a3"] { _ = try await file.rendition(rendition, fetchedIn: Array.init) }
        await file.stop()

        #expect(reader.bytesRead <= data.count + Self.formatLook, "\(reader.bytesRead) of \(data.count)")
        // The file is 1.4 MB, six blocks of 256 KB. The first look, the headers, the index and
        // the last segment's audio are read alone, before any segment; the rest in two.
        #expect(reader.requests <= 6)
    }

    @Test("segments asked for all at once are the ones asked for one by one, and no part of the file is read twice but its first look")
    func segmentsAskedForAtOnceMatchOneByOne() async throws {
        let renditions = ["v", "a0", "a1", "a2", "a3"]
        let oneByOne = try await DeliveredFile.start("four-audio-tracks")
        var paths: [String] = []
        var expected: [String: Data] = [:]
        for rendition in renditions {
            for index in try await oneByOne.segmentSeconds(of: "\(rendition).m3u8").indices {
                let path = "\(rendition)-\(index).m4s"
                paths.append(path)
                expected[path] = try await oneByOne.bytes(path)
            }
        }
        await oneByOne.stop()

        let data = try BridgeFixture.data("four-audio-tracks")
        let reader = CountingReader(data)
        let file = try await DeliveredFile.start(reading: reader, named: "four-audio-tracks.mkv")
        let atOnce = try await withThrowingTaskGroup(of: (String, Data).self) { group in
            for path in paths { group.addTask { (path, try await file.bytes(path)) } }
            return try await group.reduce(into: [:]) { $0[$1.0] = $1.1 }
        }
        await file.stop()

        #expect(atOnce == expected)
        #expect(reader.bytesRead <= data.count + Self.formatLook, "\(reader.bytesRead) of \(data.count)")
    }

    @Test("a segment whose read failed is read whole when it is asked for again")
    func segmentAfterAFailedReadIsWhole() async throws {
        let data = try BridgeFixture.data("h264-mkvmerge")
        let whole = try await DeliveredFile.start("h264-mkvmerge")
        let expected = try await whole.bytes("v-3.m4s")
        await whole.stop()

        let reader = FailingOnceReader(data: data)
        let file = try await DeliveredFile.start(reading: reader, named: "h264-mkvmerge.mkv")
        reader.failNextRead()
        await #expect(throws: (any Error).self) { try await file.bytes("v-3.m4s") }
        let again = try await file.bytes("v-3.m4s")
        await file.stop()

        #expect(again == expected)
    }
}
