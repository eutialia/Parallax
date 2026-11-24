import AVFoundation
import CryptoKit
import Foundation
import ParallaxCore
import Testing
@testable import ParallaxPlayback

/// Audio the bridge decodes and encodes again as FLAC, read back from its segments by Apple's
/// decoder.
///
/// One case at a time: `copyNextSampleBuffer` blocks its thread.
@Suite("Converted audio", .serialized)
struct ConvertedAudioTests {
    /// One segment as Apple's decoder reads it.
    struct Segment {
        /// 24 bits in the top of each 32, every channel of a sample frame in a row.
        let samples: [Int32]
        let channelCount: Int
        /// Where the segment's first sample is on the track's timeline, in sample frames.
        let start: Int64

        var frameCount: Int { samples.count / channelCount }

        func channel(_ index: Int) -> [Int32] {
            stride(from: index, to: samples.count, by: channelCount).map { samples[$0] }
        }
    }

    private static func session(_ name: String) async throws -> BridgeSession {
        try await BridgeSession.open(
            InMemoryRandomAccessReader(data: BridgeFixture.data(name)), support: BridgeFixture.everyDecoder, showsHDR: true)
    }

    private static func bytes(_ session: BridgeSession, _ path: String) async throws -> Data {
        try await #require(try await session.resource(at: path)).bytes()
    }

    /// Every segment of audio rendition `track`, asked for in `order`, in the track's order.
    private static func segments(
        of track: Int, in session: BridgeSession, order: [Int]? = nil
    ) async throws -> [Segment] {
        let initSegment = try await bytes(session, "a\(track)-init.mp4")
        var read: [Int: Segment] = [:]
        // AVAssetReader reads one fragment of a fragmented file, so each segment is its own file.
        for index in order ?? Array(session.plan.audio[track].segments.indices) {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).mp4")
            let file = initSegment + (try await bytes(session, "a\(track)-\(index).m4s"))
            try file.write(to: url)
            defer { try? FileManager.default.removeItem(at: url) }

            let asset = AVURLAsset(url: url)
            let audio = try #require(try await asset.loadTracks(withMediaType: .audio).first)
            let description = try #require(try await audio.load(.formatDescriptions).first)
            let format = try #require(CMAudioFormatDescriptionGetStreamBasicDescription(description)).pointee
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: audio, outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
            ])
            reader.add(output)
            #expect(reader.startReading())
            var samples: [Int32] = []
            while let buffer = output.copyNextSampleBuffer() {
                let block = try #require(CMSampleBufferGetDataBuffer(buffer))
                var chunk = [Int32](repeating: 0, count: CMBlockBufferGetDataLength(block) / 4)
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: chunk.count * 4, destination: &chunk)
                samples += chunk
            }
            #expect(reader.status == .completed, "segment \(index): \(String(describing: reader.error))")
            // AVAssetReader starts every file at zero. libavformat reads where the fragment says
            // it is, in the track's ticks, which are sample frames.
            read[index] = Segment(
                samples: samples, channelCount: Int(format.mChannelsPerFrame),
                start: try #require(try readBackSamples(of: file, pathExtension: "mp4").first).presentation)
        }
        return read.sorted { $0.key < $1.key }.map(\.value)
    }

    @Test(
        "a lossless track's segments, asked for in any order, hold the samples ffmpeg decodes from the file, each segment starting where the one before ends",
        arguments: [("truehd-51", 6, 48_000), ("truehd-96k", 6, 96_000), ("pcm-71", 8, 48_000)])
    func losslessTrackKeepsEverySample(name: String, channelCount: Int, sampleRate: Int) async throws {
        let session = try await Self.session(name)
        let order = session.plan.audio[0].segments.indices.shuffled()
        let segments = try await Self.segments(of: 0, in: session, order: order)
        let master = String(decoding: try await Self.bytes(session, "master.m3u8"), as: UTF8.self)

        #expect(master.contains(#",fLaC""#), "\(master)")
        #expect(master.contains(#"CHANNELS="\#(channelCount)""#), "\(master)")
        #expect(segments.map(\.channelCount) == segments.map { _ in channelCount })
        let hash = SHA256.hash(data: segments.flatMap(\.samples).withUnsafeBytes { Data($0) })
        let expected = String(decoding: try BridgeFixture.data("\(name).samples", "sha256"), as: UTF8.self)
        #expect(
            hash.map { String(format: "%02x", $0) }.joined() == expected,
            "asked for in order \(order): \(segments.map(\.frameCount)) sample frames")
        #expect(
            zip(segments, segments.dropFirst()).map { $1.start - $0.start } == segments.dropLast().map { Int64($0.frameCount) },
            "segments start at \(segments.map(\.start))")
    }

    /// The fixtures put a tone of its own in each channel, in the order the codec stores them.
    /// FLAC has one set of speakers for each channel count. A track with another set gets the
    /// smallest of FLAC's that holds its speakers, and silence (nil) in the ones it lacks.
    @Test("each channel of a converted track is the source's speaker, and a speaker the source lacks is silent", arguments: [
        // Front left and right, center, subwoofer, then the surrounds.
        ("ac3-dts-51", 1, [300.0, 400, 500, 60, 600, 700]), ("truehd-51", 0, [300, 400, 500, 60, 600, 700]),
        ("pcm-71", 0, [300, 400, 500, 60, 600, 700, 800, 900]),
        // 2.1 has no center: as three channels its subwoofer would play from one.
        ("truehd-21", 0, [300, 400, nil, 60, nil, nil]),
        // 4.0 has a center and one rear speaker, which 6.1 has between the subwoofer and the sides.
        ("truehd-40", 0, [300, 400, 500, nil, 650, nil, nil]),
    ])
    func channelsKeepTheirPlaces(name: String, track: Int, tones: [Double?]) async throws {
        // The second segment, which starts in the middle of the stream.
        let segment = try await Self.segments(of: track, in: try await Self.session(name), order: [1])[0]

        #expect(segment.channelCount == tones.count)
        // A tenth of a second holds whole cycles of every tone.
        let window = 4800..<9600
        let loudest = (0..<segment.channelCount).map { channel -> Double? in
            let samples = segment.channel(channel)[window].map(Double.init)
            guard samples.contains(where: { $0 != 0 }) else { return nil }
            return tones.compactMap(\.self).max { Self.share(of: $0, in: samples) < Self.share(of: $1, in: samples) }
        }
        #expect(loudest == tones)
    }

    /// How much of `samples`' energy is a tone of `hertz`, at 48 kHz.
    private static func share(of hertz: Double, in samples: [Double]) -> Double {
        let phase = samples.indices.map { 2 * Double.pi * hertz * Double($0) / 48_000 }
        let sine = zip(samples, phase).reduce(0) { $0 + $1.0 * sin($1.1) }
        let cosine = zip(samples, phase).reduce(0) { $0 + $1.0 * cos($1.1) }
        let total = samples.reduce(0) { $0 + $1 * $1 }
        return total > 0 ? (sine * sine + cosine * cosine) * 2 / Double(samples.count) / total : 0
    }

    /// A lossy decoder carries what it decoded into the next frame, so a segment decoded from
    /// half a second before its start is not bit for bit a decode from the start of the file.
    /// Measured: 2 of 24 bits at most for MP3, Vorbis, WMA and DTS, and one step of 16 bits for
    /// MP2, whose decoder gives 16 and dithers them.
    ///
    @Test("a stream whose opening decodes to frames with no time starts at its first packet's time")
    func untimedOpeningStartsAtItsFirstPacket() async throws {
        let demuxer = try await BridgeFixture.demuxer("vorbis")
        let stream = try #require(demuxer.streams.first { $0.kind == .audio })
        let packets = try await demuxer.packets(stream.index, from: 0, to: 1)
        // A Vorbis decoder gives nothing for its first packet, so no frame is timed.
        let untimed = packets.enumerated().map { index, packet in
            MediaPacket(
                stream: packet.stream, presentationTime: index == 0 ? 40_000_000 : nil, decodeTime: nil,
                duration: packet.duration, isKeyframe: packet.isKeyframe, data: packet.data)
        }

        #expect(ConvertedAudio(stream, openingWith: untimed)?.start == 40_000_000)
    }

    /// `vorbis-bursts` is libvorbis's encode of a tone with bursts of noise, where its frames
    /// change length, and the frame after a change is timed 9 ms from where its samples are.
    /// `mp3-44k` has frames of 26.122 ms timed to the millisecond, after a first one of 47
    /// samples: a segment that places its frames by their times alone is two samples off.
    @Test("a lossy track's segments hold what one decode of the whole stream gives, to within two steps of the depth its decoder gives, each segment starting where the one before ends", arguments: [
        ("mp3", 0, 24), ("mp2", 0, 16), ("vorbis", 0, 24), ("vorbis-bursts", 0, 24), ("wma", 0, 24), ("ac3-dts-51", 1, 24),
        ("mp3-44k", 0, 24), ("ts-mp2.ts", 0, 16),
    ])
    func lossyTrackMatchesOneDecodeOfTheStream(name: String, track: Int, bits: Int) async throws {
        let session = try await Self.session(name)
        let segments = try await Self.segments(of: track, in: session)

        let demuxer = try await BridgeFixture.demuxer(name)
        let stream = session.plan.audio[track].rendition.stream
        let packets = try await demuxer.packets(
            stream.index, from: 0, to: demuxer.keyframes().count, takingLaterAudio: true)
        let decoder = try AudioDecoder(stream.parameters)
        var whole: [Int32] = []
        for packet in packets { try decoder.decode(packet) { whole += $0.samples } }
        try decoder.finish { whole += $0.samples }

        let converted = segments.flatMap(\.samples)
        #expect(converted.count == whole.count, "\(segments.map(\.frameCount)) at \(segments.map(\.start)), whole \(whole.count / 2)")
        let furthest = zip(converted, whole).map { abs(Int64($0) - Int64($1)) }.max() ?? 0
        #expect(furthest <= 2 << (32 - bits), "\(furthest) of 32 bits")
        #expect(
            zip(segments, segments.dropFirst()).map { $1.start - $0.start } == segments.dropLast().map { Int64($0.frameCount) },
            "segments start at \(segments.map(\.start))")
    }

    /// A frame of 500 samples at 8 kHz is 62.5 ms, which a Matroska file stores as 62 or 63.
    /// The times alone then place a run of frames to half a millisecond, and nothing else in
    /// the file says more.
    @Test("a stream whose packets change length after the file's opening gains or loses a millisecond at most where segments join")
    func unevenPacketsStayWithinAMillisecond() async throws {
        // PCM at 8 kHz: 1.536 s in packets of 1024 samples, then 3 s in packets of 500.
        let segments = try await Self.segments(of: 0, in: try await Self.session("pcm-uneven"))

        let frames = segments.map(\.frameCount).reduce(0, +)
        #expect(abs(frames - 36_288) <= 8, "\(frames) sample frames")
    }

    @Test("where a stream has no packets for a while, its segments hold silence and keep their length")
    func holeInTheStreamIsSilence() async throws {
        // A 440 Hz tone with nothing from 1.502 s to 2.702 s, across the join at 2 s.
        let session = try await Self.session("mp2-hole")
        let segments = try await Self.segments(of: 0, in: session)
        let clock = session.plan.audio[0].rendition.clock

        #expect(segments.count == 2)
        #expect(segments[1].start == clock.ticks(at: 2_000_000_000))
        #expect(segments[1].start - segments[0].start == Int64(segments[0].frameCount))
        let samples = segments.flatMap { $0.channel(0) }
        // The container times a frame to the millisecond: 48 samples.
        let hole = Int(clock.ticks(at: 1_502_000_000) - segments[0].start) + 48
            ..< Int(clock.ticks(at: 2_702_000_000) - segments[0].start) - 48
        #expect(samples[hole].allSatisfy { $0 == 0 })
        // Half a second on either side, clear of the frames next to the hole.
        for tone in [samples[40_000..<64_000], samples[136_000..<160_000]] {
            #expect(Self.share(of: 440, in: tone.map(Double.init)) > 0.9)
        }
    }
}
