import AVFoundation
import Foundation
import ParallaxCore
import Synchronization
import Testing
import ParallaxTestScaling
@testable import ParallaxPlayback

@Suite("BridgeSession", .scaledTimeLimit())
struct BridgeSessionTests {

    private static func session(
        _ name: String, fragmentLimits: FragmentLimits = .standard, support: AVPlayerSupport = BridgeFixture.everyDecoder
    ) async throws -> BridgeSession {
        try await BridgeSession.open(
            InMemoryRandomAccessReader(data: BridgeFixture.data(name)), support: support, showsHDR: true,
            fragmentLimits: fragmentLimits)
    }

    private static func bytes(_ session: BridgeSession, _ path: String) async throws -> Data {
        try await #require(try await session.resource(at: path)).bytes()
    }

    @Test(
        "a rendition's segments, asked for out of order, hold every source sample once, on one timeline with the other rendition",
        arguments: [("v", 0, Int64(12_520), Int64(5000)), ("a0", 1, 4000, 1024)])
    func segmentsHoldEverySourceSampleOnOneTimeline(
        rendition: String, stream: Int, first: Int64, step: Int64
    ) async throws {
        let session = try await Self.session("h264-mkvmerge")
        var segments: [Int: Data] = [:]
        for index in [3, 0, 5, 1, 4, 2] {
            segments[index] = try await Self.bytes(session, "\(rendition)-\(index).m4s")
        }
        let file = try await Self.bytes(session, "\(rendition)-init.mp4") + (0..<6).flatMap { segments[$0] ?? Data() }

        let readBack = try readBackSamples(of: file, pathExtension: "mp4")
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
    /// the player tests below show its pictures.
    @Test("a transport stream's segments, asked for out of order, hold every source sample once, in the form an MP4 holds it")
    func transportStreamSegmentsHoldEverySourceSample() async throws {
        let session = try await Self.session("ts-h264.ts")
        func file(_ rendition: String) async throws -> Data {
            var segments: [Int: Data] = [:]
            for index in [3, 0, 5, 1, 4, 2] {
                segments[index] = try await Self.bytes(session, "\(rendition)-\(index).m4s")
            }
            return try await Self.bytes(session, "\(rendition)-init.mp4") + (0..<6).flatMap { segments[$0] ?? Data() }
        }
        let video = try readBackSamples(of: try await file("v"), pathExtension: "mp4")
        let aac = try readBackSamples(of: try await file("a0"), pathExtension: "mp4")
        let ac3 = try readBackSamples(of: try await file("a1"), pathExtension: "mp4")

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
          arguments: [("flv-h264.flv", true, Int64(1024)), ("avi-h264.avi", false, 1536), ("asf-h264.asf", false, 1536)])
    func segmentsHoldEverySourceSample(name: String, videoIsInMP4Form: Bool, audioFrameLength: Int64) async throws {
        let session = try await Self.session(name)
        func file(_ rendition: String) async throws -> Data {
            var segments: [Int: Data] = [:]
            for index in [3, 0, 5, 1, 4, 2] {
                segments[index] = try await Self.bytes(session, "\(rendition)-\(index).m4s")
            }
            return try await Self.bytes(session, "\(rendition)-init.mp4") + (0..<6).flatMap { segments[$0] ?? Data() }
        }
        let video = try readBackSamples(of: try await file("v"), pathExtension: "mp4")
        let audio = try readBackSamples(of: try await file("a0"), pathExtension: "mp4")
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
        let session = try await Self.session("ts-audio-gap.ts")
        var file = try await Self.bytes(session, "a0-init.mp4")
        for index in try #require(session.plan.audio.first).segments.indices {
            file += try await Self.bytes(session, "a0-\(index).m4s")
        }

        let readBack = try readBackSamples(of: file, pathExtension: "mp4").map(\.presentation)
        let first = try #require(readBack.first)

        let firstPart: [Int64] = (0..<184).map { $0 * 1024 }
        let secondPart: [Int64] = (0..<184).map { 192_000 + $0 * 1024 }
        #expect(readBack.map { $0 - first } == firstPart + secondPart)
    }

    @Test("AAC at 44.1 kHz, which a transport stream times to the nearest tick, plays a frame after a frame")
    func audioTimedToTheNearestTickIsEvenlySpaced() async throws {
        let session = try await Self.session("ts-aac-44100.ts")
        var file = try await Self.bytes(session, "a0-init.mp4")
        for index in try #require(session.plan.audio.first).segments.indices {
            file += try await Self.bytes(session, "a0-\(index).m4s")
        }

        let readBack = try readBackSamples(of: file, pathExtension: "mp4").map(\.presentation)

        #expect(readBack.count > 170)
        #expect(zip(readBack.dropFirst(), readBack).allSatisfy { $0 - $1 == 1024 })
    }

    /// An MP4 sample of E-AC-3 holds six blocks, so the muxer joins frames of three into pairs,
    /// and libavformat's demuxer splits them again on reading. The fixture's 375 frames fall 125
    /// to a two-second segment, and the last has no partner.
    @Test(
        "an E-AC-3 rendition of three-block frames, a frame per fragment, holds every frame but an unpaired last one, evenly spaced",
        arguments: [FragmentLimits.standard, FragmentLimits(bytes: 1, duration: .seconds(Int64.max))])
    func shortEAC3FramesArePairedAcrossSegments(fragmentLimits: FragmentLimits) async throws {
        let session = try await Self.session("eac3-three-blocks", fragmentLimits: fragmentLimits)
        let segments = try #require(session.plan.audio.first).segments
        var file = try await Self.bytes(session, "a0-init.mp4")
        for index in segments.indices {
            file += try await Self.bytes(session, "a0-\(index).m4s")
        }

        let readBack = try readBackSamples(of: file, pathExtension: "mp4")
        let first = try #require(readBack.first?.presentation)

        #expect(readBack.count == 374)
        #expect(readBack.map(\.presentation) == readBack.indices.map { first + Int64($0) * 768 })
    }

    /// The fixture's 126 frames end on a pair that starts before the segment boundary at 2 s and
    /// ends after it, so the track's audio ends in the first segment.
    @Test("an E-AC-3 track of three-block frames that ends on a pair across a segment boundary lists only segments that build")
    func shortEAC3PairAcrossTheLastBoundary() async throws {
        let session = try await Self.session("eac3-three-blocks-ends-early")
        let segments = try #require(session.plan.audio.first).segments
        var file = try await Self.bytes(session, "a0-init.mp4")
        for index in segments.indices {
            file += try await Self.bytes(session, "a0-\(index).m4s")
        }

        let readBack = try readBackSamples(of: file, pathExtension: "mp4")
        let first = try #require(readBack.first?.presentation)

        #expect(segments.count == 1)
        #expect(readBack.count == 126)
        #expect(readBack.map(\.presentation) == readBack.indices.map { first + Int64($0) * 768 })
    }

    /// The fixture's header declares 23.976 frames a second. Its first two seconds run at 59.94.
    @Test(
        "video faster than its declared rate keeps each frame at its own time, a frame per fragment or not",
        arguments: [FragmentLimits.standard, FragmentLimits(bytes: 1, duration: .seconds(Int64.max))])
    func videoFasterThanDeclaredKeepsItsTimes(fragmentLimits: FragmentLimits) async throws {
        let session = try await Self.session("rate-above-declared", fragmentLimits: fragmentLimits)
        var file = try await Self.bytes(session, "v-init.mp4")
        for index in session.plan.video.segments.indices {
            file += try await Self.bytes(session, "v-\(index).m4s")
        }
        let demuxer = try await BridgeFixture.demuxer("rate-above-declared")
        let source = try await demuxer.packets(from: 0, to: demuxer.keyframes().count)
            .filter { $0.stream == 0 }.compactMap(\.presentationTime).sorted()

        let readBack = try readBackSamples(of: file, pathExtension: "mp4").map(\.presentation).sorted()
        let offsets = zip(readBack, source).map { Double($0) / 120_000 - Double($1) / 1e9 }

        #expect(readBack.count == source.count)
        // A millisecond: the container's tick.
        #expect((offsets.max() ?? 0) - (offsets.min() ?? 0) <= 0.001)
    }

    /// AVPlayer keeps playing video over audio it cannot decode and reports nothing, so the
    /// frame test below cannot vouch for audio. This one hands the rendition to Apple's
    /// decoder directly. Every fixture's audio is a tone, at an eighth of full scale.
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
        // WMA converted to FLAC, timed by an ASF's packets in whole milliseconds.
        ("numbered-wmv2.asf", "a0", 440, 5, 12),
        // AC-3 copied out of a program stream, where some frames carry the time of the frame after them.
        ("numbered-mpeg2.mpg", "a0", 440, 6, 12),
    ])
    func audioRenditionDecodesToTheSourceTone(
        name: String, rendition: String, hertz: Double, segmentCount: Int, seconds: Double
    ) async throws {
        let session = try await Self.session(name)
        let initSegment = try await Self.bytes(session, "\(rendition)-init.mp4")
        var segments: [[Int16]] = []
        // AVAssetReader reads one fragment of a fragmented file, so each segment is its own file.
        for index in 0..<segmentCount {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).mp4")
            try (initSegment + (try await Self.bytes(session, "\(rendition)-\(index).m4s"))).write(to: url)
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
            #expect(reader.status == .completed, "segment \(index): \(String(describing: reader.error))")
            segments.append(samples)
        }

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

    @Test("a path the plan does not have is no resource", arguments: [
        "v-6.m4s", "v-007.m4s", "v--1.m4s", "x-0.m4s", "v.mp4", "master", "a0-init.m4s", "a-0.m4s", "a00-0.m4s", "a2-0.m4s", "",
    ])
    func unknownPathIsNoResource(path: String) async throws {
        #expect(try await Self.session("h264-mkvmerge").resource(at: path) == nil)
    }

    /// Passes every request through, and remembers the paths in the order they came.
    private final class RecordingResponder: MediaResponder {
        let session: BridgeSession
        private let recorded = Mutex<[String]>([])

        init(_ session: BridgeSession) { self.session = session }

        var entryPath: String { session.entryPath }
        var paths: [String] { recorded.withLock { $0 } }

        func resource(at path: String) async throws -> ServedResource? {
            recorded.withLock { $0.append(path) }
            return try await session.resource(at: path)
        }

        func role(of path: String) -> String? {
            session.role(of: path)
        }
    }

    private struct ShownFrame: CustomStringConvertible {
        /// The item time AVPlayer displays the frame at.
        let seconds: Double
        /// The number the picture itself carries.
        let number: Int

        var description: String { String(format: "#%d at %.4f s", number, seconds) }
        /// The fixture runs at 24 frames per second from item time zero.
        var isTheSourceFrameForItsTime: Bool { number == Int((seconds * 24).rounded()) }
    }

    /// Every new frame AVPlayer displays during `duration` of wall-clock time.
    @MainActor
    private static func framesShown(by output: AVPlayerItemVideoOutput, for duration: Duration) async -> [ShownFrame] {
        var shown: [ShownFrame] = []
        let clock = ContinuousClock()
        let end = clock.now + duration
        while clock.now < end {
            let time = output.itemTime(forHostTime: CACurrentMediaTime())
            var displayed = CMTime.invalid
            if output.hasNewPixelBuffer(forItemTime: time),
               let buffer = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: &displayed) {
                shown.append(ShownFrame(seconds: displayed.seconds, number: BridgeFixture.frameNumber(in: buffer)))
            }
            try? await Task.sleep(for: .milliseconds(4))
        }
        return shown
    }

    @Test("serving every segment of every track reads no part of the file twice, and in few requests")
    func eachPartOfTheFileIsReadOnce() async throws {
        let reader = CountingReader(data: try BridgeFixture.data("four-audio-tracks"))
        let session = try await BridgeSession.open(reader, support: BridgeFixture.everyDecoder, showsHDR: true)
        for (id, track) in [(RenditionID.video, session.plan.video)]
            + session.plan.audio.indices.map({ (RenditionID.audio($0), session.plan.audio[$0]) }) {
            for index in track.segments.indices {
                _ = try await session.resource(at: BridgeResource.mediaSegment(id, index).path)
            }
        }
        #expect(reader.bytesRead <= reader.data.count)
        // The file is 1.4 MB, six blocks of 256 KB. The headers, the index and the last
        // segment's audio are read alone, before any segment; the rest in two.
        #expect(reader.requests <= 5)
    }

    @Test("segments asked for all at once, each read by a demuxer of its own, are the ones asked for one by one, and no part of the file is read twice")
    func segmentsAskedForAtOnceMatchOneByOne() async throws {
        let paths = { (plan: BridgePlan) in
            ([(RenditionID.video, plan.video)] + plan.audio.indices.map { (RenditionID.audio($0), plan.audio[$0]) })
                .flatMap { id, track in track.segments.indices.map { BridgeResource.mediaSegment(id, $0).path } }
        }
        let oneByOne = try await Self.session("four-audio-tracks")
        var expected: [String: Data] = [:]
        for path in paths(oneByOne.plan) { expected[path] = try await Self.bytes(oneByOne, path) }

        let reader = CountingReader(data: try BridgeFixture.data("four-audio-tracks"))
        let session = try await BridgeSession.open(reader, support: BridgeFixture.everyDecoder, showsHDR: true)
        let atOnce = try await withThrowingTaskGroup(of: (String, Data).self) { group in
            for path in paths(session.plan) { group.addTask { (path, try await Self.bytes(session, path)) } }
            return try await group.reduce(into: [:]) { $0[$1.0] = $1.1 }
        }

        #expect(atOnce == expected)
        #expect(reader.bytesRead <= reader.data.count)
    }

    @Test("the first fragment of a 32-second segment is handed over before the segment's last packet is read")
    func firstFragmentComesBeforeTheSegmentIsRead() async throws {
        let reader = CountingReader(data: try BridgeFixture.data("long-span"))
        // Blocks of 4 KB, few kept, and fragments of 16 KB: the segment is 141 KB.
        let session = try await BridgeSession.open(
            reader, support: BridgeFixture.everyDecoder, showsHDR: true, blockSize: 4096, bytesKept: 64 << 10,
            fragmentLimits: FragmentLimits(bytes: 16 << 10, duration: .seconds(Int64.max)))
        try #require(session.plan.video.segments[0].entries == 0..<1)
        guard case .streamed(let produce) = try #require(try await session.resource(at: "v-0.m4s")).body else {
            Issue.record("a media segment is streamed")
            return
        }
        _ = reader.takeFurthest()

        let producer = produce()
        let first = try await producer.next()
        let furthest = reader.takeFurthest()
        producer.cancel()

        #expect(first?.isEmpty == false)
        #expect(furthest < session.keyframes[1].position)
    }

    @Test("a converted audio segment reads half a second ahead of its span, not the whole span before it")
    func convertedAudioReadsLittleBeforeItsSpan() async throws {
        let reader = CountingReader(data: try BridgeFixture.data("ts-mp2.ts"))
        // Sampled as a large recording is: a listed keyframe every 300 KB or so, five seconds apart.
        let session = try await BridgeSession.open(
            reader, support: BridgeFixture.everyDecoder, showsHDR: true, blockSize: 4096, bytesKept: 64 << 10,
            listing: .init(wholeReadSize: 0, sampling: .init(densestSpacing: 300_000, largestSegment: 300_000)))
        let segment = try #require(session.plan.audio.first?.segments.dropFirst().first)
        try #require(session.plan.audio[0].segments.count > 2)
        let span = Int(
            session.keyframes[segment.entries.upperBound].position - session.keyframes[segment.entries.lowerBound].position)
        let readAtOpen = reader.bytesRead

        _ = try await Self.bytes(session, "a0-1.m4s")

        #expect(reader.bytesRead - readAtOpen < span + span / 2, "\(reader.bytesRead - readAtOpen) bytes for a span of \(span)")
    }

    @Test("a segment read cancelled after its first fragment fetches at most one more read, and returns")
    func cancelledSegmentStopsItsRead() async throws {
        let reader = CountingReader(data: try BridgeFixture.data("long-span"))
        let session = try await BridgeSession.open(
            reader, support: BridgeFixture.everyDecoder, showsHDR: true, blockSize: 4096, bytesKept: 64 << 10,
            fragmentLimits: FragmentLimits(bytes: 16 << 10, duration: .seconds(Int64.max)))
        guard case .streamed(let produce) = try #require(try await session.resource(at: "v-0.m4s")).body else {
            Issue.record("a media segment is streamed")
            return
        }

        let producer = produce()
        _ = try await producer.next()
        producer.cancel()
        let readAtCancel = reader.bytesRead
        await session.reads.allReturned()

        #expect(session.reads.count == 0)
        #expect(reader.bytesRead - readAtCancel <= SessionBlockCache.defaultBlocksPerRead * 4096)
        #expect(session.report(of: []).bytesFetched == reader.bytesRead)
    }

    @Test("the report at stop sums the request log: bytes served and read, the slowest first byte, the drops and the largest segment")
    func reportSumsTheRequestLog() {
        func record(_ resource: String, sent: Int, firstByte: Int?, _ ending: RequestRecord.Ending = .complete) -> RequestRecord {
            RequestRecord(
                resource: resource, status: 200, firstByte: firstByte.map { .milliseconds($0) }, duration: .seconds(1),
                bytesSent: sent, bytesFetched: sent, ending: ending)
        }
        let peaks = BridgeMemory.Peaks(bridge: 40 << 20, footprint: 300 << 20, lowestHeadroom: 2 << 30)
        let report = BridgeReport(
            records: [
                record("master.m3u8", sent: 900, firstByte: 1),
                record("v-0.m4s", sent: 3 << 20, firstByte: 120),
                record("a0-0.m4s", sent: 1 << 20, firstByte: 1_400, .dropped),
                record("v-1.m4s", sent: 0, firstByte: nil, .failed(afterBytes: 0, reason: "timed out")),
            ],
            bytesFetched: 6 << 20, memory: peaks, readsRunning: 1, conversionSpeeds: [60, 12.5, 48])

        #expect(report.requests == 4)
        #expect(report.bytesServed == (4 << 20) + 900)
        #expect(report.worstFirstByte == .milliseconds(1_400))
        #expect(report.dropped == 1)
        #expect(report.largestSegment == 3 << 20)
        #expect(report.description == "bridge: 4 requests, 4 MB served, 6 MB read (1.50x), worst first byte 1400 ms, "
            + "1 dropped, largest segment 3 MB, bridge peak 40 MB, footprint peak 300 MB, lowest headroom 2048 MB, "
            + "1 reads not returned, conversion 12.5x at its slowest, 48.0x in the middle")
    }

    @Test("the report gives a speed for each converted segment asked for, and none for a copied one")
    func reportTimesConvertedSegments() async throws {
        // The second audio track is AC-3, copied. The third is DTS, converted.
        let session = try await Self.session("four-audio-tracks")

        _ = try await Self.bytes(session, "a1-0.m4s")
        #expect(session.report(of: []).slowestConversion == nil)
        _ = try await Self.bytes(session, "a2-0.m4s")
        _ = try await Self.bytes(session, "a2-1.m4s")
        #expect(session.conversions.all.count == 2)
        // Decoding and encoding two seconds of stereo takes a Mac a few milliseconds.
        #expect(try #require(session.report(of: []).slowestConversion) > 1)
    }

    @Test("a segment whose read failed is read whole when it is asked for again")
    func segmentAfterAFailedReadIsWhole() async throws {
        let data = try BridgeFixture.data("h264-mkvmerge")
        let reader = FailingOnceReader(data: data)
        // Few blocks kept, so the second ask reads the share again.
        let session = try await BridgeSession.open(
            reader, support: BridgeFixture.everyDecoder, showsHDR: true, blockSize: 4096, bytesKept: 16 << 10)
        let expected = try await Self.bytes(Self.session("h264-mkvmerge"), "v-3.m4s")

        reader.failNextRead()
        await #expect(throws: (any Error).self) { try await Self.bytes(session, "v-3.m4s") }
        #expect(try await Self.bytes(session, "v-3.m4s") == expected)
    }

    private final class FailingOnceReader: RandomAccessReading {
        struct Dropped: Error {}
        let data: Data
        private let failing = Mutex(false)

        init(data: Data) { self.data = data }

        func failNextRead() { failing.withLock { $0 = true } }

        var fileSize: UInt64 { get async throws { UInt64(data.count) } }

        func read(offset: UInt64, length: Int) async throws -> Data {
            if failing.withLock({ defer { $0 = false }; return $0 }) { throw Dropped() }
            return try await InMemoryRandomAccessReader(data: data).read(offset: offset, length: length)
        }
    }

    private final class CountingReader: RandomAccessReading {
        let data: Data
        private let count = Mutex((bytes: 0, requests: 0))
        /// The furthest byte read since the last `takeFurthest`.
        private let furthest = Mutex<Int64>(0)
        var bytesRead: Int { count.withLock { $0.bytes } }
        var requests: Int { count.withLock { $0.requests } }

        func takeFurthest() -> Int64 { furthest.withLock { defer { $0 = 0 }; return $0 } }

        init(data: Data) { self.data = data }

        var fileSize: UInt64 { get async throws { UInt64(data.count) } }

        func read(offset: UInt64, length: Int) async throws -> Data {
            let read = try await InMemoryRandomAccessReader(data: data).read(offset: offset, length: length)
            count.withLock { $0 = (bytes: $0.bytes + read.count, requests: $0.requests + 1) }
            furthest.withLock { $0 = max($0, Int64(offset) + Int64(read.count)) }
            return read
        }
    }

    /// A fixture served over loopback and loaded into a player that is ready to play it.
    @MainActor
    private struct LoadedFixture {
        let responder: RecordingResponder
        let server: LocalMediaServer
        let output: AVPlayerItemVideoOutput
        let player: AVPlayer

        init(
            _ name: String, fragmentLimits: FragmentLimits = .standard,
            support: AVPlayerSupport = BridgeFixture.everyDecoder
        ) async throws {
            responder = RecordingResponder(
                try await BridgeSessionTests.session(name, fragmentLimits: fragmentLimits, support: support))
            server = LocalMediaServer(responder: responder)
            let item = AVPlayerItem(url: try await server.start(scope: .loopback))
            // Three seconds keeps AVPlayer from fetching all of a minute-long file.
            item.preferredForwardBufferDuration = 3
            output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            ])
            item.add(output)
            player = AVPlayer(playerItem: item)
            player.isMuted = true

            let clock = ContinuousClock()
            let deadline = clock.now + CITimeScale.seconds(15)
            while item.status == .unknown, clock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            if item.status != .readyToPlay {
                await server.stop()
                Issue.record("the item never became ready: \(String(describing: item.error)), after \(responder.paths)")
            }
            try #require(item.status == .readyToPlay)
        }

        /// Seeks to exactly `seconds`, plays, and returns the frames shown in the next `duration`.
        func framesShown(from seconds: Double? = nil, for duration: Duration) async -> [ShownFrame] {
            if let seconds {
                await player.seek(
                    to: CMTime(seconds: seconds, preferredTimescale: 24_000), toleranceBefore: .zero, toleranceAfter: .zero)
            }
            player.play()
            let shown = await BridgeSessionTests.framesShown(by: output, for: duration)
            player.pause()
            return shown
        }
    }

    @MainActor
    @Test(
        "AVPlayer shows each source frame at its own time, from the start and after a seek past what it had buffered",
        arguments: [
            ("frame-numbers", FragmentLimits.standard), ("frame-numbers-hevc", .standard),
            // The opening holds pictures shown later than its last: they must not be ranked.
            ("deep-pyramid-hevc", .standard),
            // Each picture in a fragment of its own: every fragment after a segment's first is
            // dated by the writer, open-GOP pictures included.
            ("frame-numbers-hevc", FragmentLimits(bytes: 1, duration: .seconds(Int64.max))),
            // Transport streams with no index, cut at keyframes that are not IDR pictures:
            // x265's CRA pictures and x264's recovery points.
            ("ts-hevc-open-gop.ts", .standard), ("ts-h264-open-gop.ts", .standard),
        ])
    func avPlayerShowsEachSourceFrameAtItsTime(name: String, fragmentLimits: FragmentLimits) async throws {
        try await Self.expectEachSourceFrameAtItsTime(from: LoadedFixture(name, fragmentLimits: fragmentLimits))
    }

    @MainActor
    @Test(
        "AVPlayer shows each source frame of a video converted to HEVC at its own time, from the start and after a seek past what it had buffered",
        // AV1 in 10 bits on a device with no decoder for it, MPEG-2 with open groups of
        // pictures in a transport stream, and MPEG-4 with B-pictures in an AVI, which stores
        // decode times only.
        arguments: ["numbered-av1", "numbered-mpeg2-open-gop.ts", "numbered-mpeg4-b.avi"])
    func avPlayerShowsEachSourceFrameOfConvertedVideo(name: String) async throws {
        let fixture = try await LoadedFixture(name, support: BridgeFixture.fewestDecoders)
        #expect(fixture.responder.session.plan.video.rendition.codec.hasPrefix("hvc1"))
        try await Self.expectEachSourceFrameAtItsTime(from: fixture)
    }

    @MainActor
    @Test(
        "a file with no audio stream plays silent, each source frame at its own time, from the start and after a seek",
        // H.264 that is copied, and MPEG-4 with B-pictures in an AVI that is converted.
        arguments: ["numbered-h264-silent", "numbered-mpeg4-silent.avi"])
    func videoOnlyFilePlaysSilent(name: String) async throws {
        let fixture = try await LoadedFixture(name)
        let plan = fixture.responder.session.plan
        #expect(plan.audio.isEmpty)
        #expect(!HLSPlaylist.master(for: plan).contains("AUDIO"))
        try await Self.expectEachSourceFrameAtItsTime(from: fixture, hasAudio: false)
    }

    @Test("the same clip is delivered with the same video and audio codecs from every container the bridge reads",
          .disabled("Pending: needs H.264 with B-frames copied from an AVI, a WMV and an MPG"))
    func sameClipIsDeliveredTheSameFromEveryContainer() async throws {}

    /// Nine of the fixture's frames start in one PES packet and end in the next, and libavformat
    /// gives each the time of the frame after it.
    @Test("AC-3 in an MPG or VOB is copied, and its segments, asked for in any order, hold every frame once")
    func ac3InProgramStreamIsCopied() async throws {
        let name = "numbered-h264-ac3.mpg"
        let session = try await Self.session(name)
        let track = try #require(session.plan.audio.first)
        var segments: [Int: Data] = [:]
        for index in track.segments.indices.shuffled() {
            segments[index] = try await Self.bytes(session, "a0-\(index).m4s")
        }
        let file = try await Self.bytes(session, "a0-init.mp4") + track.segments.indices.flatMap { segments[$0] ?? Data() }
        let frames = try readBackSamples(of: file, pathExtension: "mp4")
        let first = try #require(frames.first?.presentation)

        #expect(track.rendition.codec == "ac-3")
        #expect(frames.map(\.md5) == (try BridgeFixture.sourcePackets(name, stream: 1).map(\.md5)))
        // 1,536 samples a frame at 48 kHz.
        #expect(frames.map(\.presentation) == frames.indices.map { first + Int64($0) * 1536 })
    }

    /// The second audio stream plays from 20 s to 24 s only: libavformat finds it neither in
    /// what it reads to describe the file nor in what it reads of the end, as a DVD's
    /// subtitles are.
    @Test("an MPG with a stream that first appears partway through is delivered without that stream, every segment of it")
    func streamFirstSeenPartwayThroughIsLeftOut() async throws {
        let session = try await Self.session("numbered-h264-late-audio.mpg")
        let plan = session.plan

        #expect(plan.audio.map(\.rendition.codec) == ["ac-3"])
        for index in plan.video.segments.indices { _ = try await Self.bytes(session, "v-\(index).m4s") }
        for index in try #require(plan.audio.first).segments.indices { _ = try await Self.bytes(session, "a0-\(index).m4s") }
    }

    @MainActor
    @Test("AVPlayer plays AC-3 copied out of an MPG from the start and after a seek, fetching its audio on both sides of the seek")
    func avPlayerPlaysAC3CopiedOutOfProgramStream() async throws {
        let fixture = try await LoadedFixture("numbered-h264-ac3.mpg")
        #expect(fixture.responder.session.plan.audio.first?.rendition.codec == "ac-3")
        try await Self.expectEachSourceFrameAtItsTime(from: fixture)
        let target = try #require(Self.segment(holding: 40.5, in: fixture.responder.session.plan))
        #expect(fixture.responder.paths.contains("a0-\(target).m4s"), "\(fixture.responder.paths)")
        #expect(fixture.player.currentItem?.error == nil)
    }

    @Test("H.264 with B-frames in an AVI or WMV is copied, and AVPlayer shows each source frame at its own time, from the start and after a seek",
          .disabled("Pending: H.264 timed by its picture order count"))
    func h264WithBFramesInDecodeTimeContainersIsCopied() async throws {}

    @Test("H.264 in an MPG or VOB is copied, and AVPlayer shows each source frame at its own time, from the start and after a seek",
          .disabled("Pending: H.264 timed by its picture order count"))
    func h264InProgramStreamIsCopied() async throws {}

    /// Plays a minute-long numbered fixture from the start, then from 40.5 s.
    @MainActor
    private static func expectEachSourceFrameAtItsTime(from fixture: LoadedFixture, hasAudio: Bool = true) async throws {
        let responder = fixture.responder

        let fromStart = await fixture.framesShown(for: .seconds(4))
        let requestedBeforeSeek = responder.paths
        let afterSeek = await fixture.framesShown(from: 40.5, for: .seconds(2))
        await fixture.server.stop()

        // Past the first segment, whose keyframe is the only one no picture is shown before.
        #expect(fromStart.count > 72, "\(fromStart)")
        #expect(fromStart.first?.number == 0)
        #expect(fromStart.filter { !$0.isTheSourceFrameForItsTime }.isEmpty)
        #expect(afterSeek.count > 24, "\(afterSeek)")
        // 40.5 s is frame 972.
        #expect(afterSeek.first?.number == 972)
        #expect(afterSeek.filter { !$0.isTheSourceFrameForItsTime }.isEmpty)

        // AVPlayer went straight to the segment that holds 40.5 s: nothing that starts between
        // 16 s, past what it had buffered at the start, and that segment was read.
        let starts = Self.segmentStarts(in: responder.session.plan)
        let target = try #require(Self.segment(holding: 40.5, in: responder.session.plan))
        let videoSegments = responder.paths.compactMap { path -> Int? in
            if case .mediaSegment(.video, let index) = BridgeResource(path: path) { index } else { nil }
        }
        #expect(requestedBeforeSeek.contains("v-0.m4s"))
        #expect(requestedBeforeSeek.contains("a0-0.m4s") == hasAudio)
        #expect(videoSegments.contains(target))
        #expect(videoSegments.filter { starts[$0] >= 16 && $0 < target }.isEmpty, "\(videoSegments)")
    }

    /// Seconds from the start at which each video segment plays.
    private static func segmentStarts(in plan: BridgePlan) -> [Double] {
        plan.video.segments.dropLast().reduce(into: [0]) { starts, segment in starts.append(starts[starts.count - 1] + segment.seconds) }
    }

    /// The index of the video segment that plays at `seconds` from the start.
    private static func segment(holding seconds: Double, in plan: BridgePlan) -> Int? {
        segmentStarts(in: plan).lastIndex { $0 <= seconds }
    }

    @MainActor
    @Test("AVPlayer plays each codec the bridge delivers", arguments: [
        "flac", "eac3", "opus", "av1", "h264-high10", "dolby-vision-8-4",
        // ALAC copied, and FLAC converted from MP3, from TrueHD in 5.1 at 48 and 96 kHz, and from
        // PCM in 7.1.
        "alac", "mp3", "truehd-51", "truehd-96k", "pcm-71",
        // A transport stream copied from a Matroska file: its times are still rounded to the
        // millisecond, under a tick ninety times finer.
        "ts-copied-from-mkv.ts",
        // H.264 as an FLV holds it, and behind start codes with no presentation times in an AVI
        // and an ASF.
        "flv-h264.flv", "avi-h264.avi", "asf-h264.asf",
    ])
    func avPlayerPlaysEachDeliveredCodec(name: String) async throws {
        let fixture = try await LoadedFixture(name)
        let shown = await fixture.framesShown(for: .seconds(2))
        await fixture.server.stop()

        // The fixtures run at 24 frames per second.
        #expect(shown.count > 24)
        #expect(fixture.player.currentItem?.error == nil)
    }

    @MainActor
    @Test("AVPlayer offers every delivered audio track, starts on the file's default, and plays another when asked")
    func avPlayerSwitchesAudioTracks() async throws {
        let fixture = try await LoadedFixture("four-audio-tracks")
        let item = try #require(fixture.player.currentItem)
        let group = try #require(try await item.asset.loadMediaSelectionGroup(for: .audible))

        // AVPlayer shows a track's language, not the playlist's name for it: the second track's
        // title, "Surround", is not shown. The file spells German "ger".
        #expect(group.options.map(\.displayName) == ["English", "Japanese", "Japanese", "German"])
        #expect(group.options.map(\.extendedLanguageTag) == ["eng", "jpn", "jpn", "ger"])
        _ = await fixture.framesShown(for: .seconds(1))
        #expect(item.currentMediaSelection.selectedMediaOption(in: group) == group.options[1])
        #expect(fixture.responder.paths.contains("a1-0.m4s"))
        #expect(!fixture.responder.paths.contains("a0-0.m4s") && !fixture.responder.paths.contains("a2-0.m4s"))

        // The third track is DTS, which the bridge converts to FLAC.
        item.select(group.options[2], in: group)
        let shown = await fixture.framesShown(for: .seconds(2))
        await fixture.server.stop()

        #expect(shown.count > 24)
        #expect(fixture.responder.paths.contains { $0.hasPrefix("a2-") && $0.hasSuffix(".m4s") })
        #expect(item.error == nil)
    }

    @MainActor
    @Test("video whose pixels are not square is shown at the shape the file gives it")
    func anamorphicVideoKeepsItsShape() async throws {
        let fixture = try await LoadedFixture("anamorphic")
        let size = try #require(fixture.player.currentItem?.presentationSize)
        await fixture.server.stop()

        // 160 by 90 stored, with pixels a third wider than tall.
        #expect((size.width.rounded(), size.height) == (213, 90))
    }

    @MainActor
    @Test("a file whose audio ends before its video plays to its last frame")
    func videoOutlastsAudio() async throws {
        let fixture = try await LoadedFixture("audio-ends-early")
        // The audio ends at 11 s and the video at 12 s. AVPlayer ends an item where its
        // shortest rendition does.
        let shown = await fixture.framesShown(from: 10, for: .seconds(3))
        await fixture.server.stop()

        #expect(shown.first?.number == 240)
        #expect(shown.last?.number == 287)
        #expect(shown.filter { !$0.isTheSourceFrameForItsTime }.isEmpty)
    }

    @MainActor
    @Test("a file whose audio ends two segments before its video plays to its last frame, from inside the audio and from past it", arguments: [6.0, 9.0])
    func videoOutlastsAudioBySegments(start: Double) async throws {
        let fixture = try await LoadedFixture("audio-ends-two-segments-early")
        // The audio ends at 8 s and the video at 12 s.
        let shown = await fixture.framesShown(from: start, for: .seconds(12 - start + 2))
        await fixture.server.stop()

        #expect(shown.first?.number == Int(start * 24))
        #expect(shown.last?.number == 287)
        #expect(shown.filter { !$0.isTheSourceFrameForItsTime }.isEmpty)
        #expect(!fixture.responder.paths.contains("a0-4.m4s"))
    }
}
