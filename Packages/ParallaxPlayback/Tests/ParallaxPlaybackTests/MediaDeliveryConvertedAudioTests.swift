import AetherLibavcodec
import AetherLibavformat
import AetherLibavutil
import AVFoundation
import CryptoKit
import Foundation
import Testing
import ParallaxTestScaling
import ParallaxPlayback

/// Audio a delivery converts to FLAC, fetched over HTTP and read back by Apple's decoder.
///
/// One case at a time: `copyNextSampleBuffer` blocks its thread.
@Suite("MediaDelivery — converted audio", .serialized, .scaledTimeLimit())
struct MediaDeliveryConvertedAudioTests {
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

    /// Every segment of `rendition` of a delivery of `name`, fetched in `order`, in the track's
    /// order, and the master playlist.
    private static func segments(
        of rendition: String, from name: String, order: (Range<Int>) -> [Int] = Array.init
    ) async throws -> (segments: [Segment], master: String) {
        let file = try await DeliveredFile.start(name)
        var fetched: [Int: Data] = [:]
        let initSegment: Data
        let master: String
        do {
            master = try await file.master
            initSegment = try await file.bytes("\(rendition)-init.mp4")
            let count = try await file.segmentSeconds(of: "\(rendition).m3u8").count
            for index in order(0..<count) { fetched[index] = try await file.bytes("\(rendition)-\(index).m4s") }
            await file.stop()
        } catch {
            await file.stop()
            throw error
        }
        var read: [Int: Segment] = [:]
        for (index, bytes) in fetched { read[index] = try await Self.decoded(initSegment + bytes, index: index) }
        return (read.sorted { $0.key < $1.key }.map(\.value), master)
    }

    /// AVAssetReader reads one fragment of a fragmented file, so each segment is its own file.
    private static func decoded(_ file: Data, index: Int) async throws -> Segment {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).mp4")
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
        return Segment(
            samples: samples, channelCount: Int(format.mChannelsPerFrame),
            start: try #require(try readBackSamples(of: file, pathExtension: "mp4").first).presentation)
    }

    /// Each fixture's audio starts 7 ms (PCM) or 7.5 ms (TrueHD) after its first picture, and
    /// the delivery starts it there with silence (`lead` sample frames).
    @Test(
        "a lossless track's segments, asked for in any order, hold the samples ffmpeg decodes from the file, each segment starting where the one before ends",
        arguments: [("truehd-51", 6, 48_000, 360), ("truehd-96k", 6, 96_000, 720), ("pcm-71", 8, 48_000, 336)])
    func losslessTrackKeepsEverySample(name: String, channelCount: Int, sampleRate: Int, lead: Int) async throws {
        var order: [Int] = []
        let (segments, master) = try await Self.segments(of: "a0", from: name) { indices in
            order = indices.shuffled()
            return order
        }

        #expect(master.contains(#",fLaC""#), "\(master)")
        #expect(master.contains(#"CHANNELS="\#(channelCount)""#), "\(master)")
        #expect(segments.map(\.channelCount) == segments.map { _ in channelCount })
        let samples = segments.flatMap(\.samples)
        #expect(samples.prefix(lead * channelCount).allSatisfy { $0 == 0 }, "\(samples.prefix(lead * channelCount))")
        let hash = SHA256.hash(data: samples.dropFirst(lead * channelCount).withUnsafeBytes { Data($0) })
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
        ("ac3-dts-51", "a1", [300.0, 400, 500, 60, 600, 700]), ("truehd-51", "a0", [300, 400, 500, 60, 600, 700]),
        ("pcm-71", "a0", [300, 400, 500, 60, 600, 700, 800, 900]),
        // 2.1 has no center: as three channels its subwoofer would play from one.
        ("truehd-21", "a0", [300, 400, nil, 60, nil, nil]),
        // 4.0 has a center and one rear speaker, which 6.1 has between the subwoofer and the sides.
        ("truehd-40", "a0", [300, 400, 500, nil, 650, nil, nil]),
    ])
    func channelsKeepTheirPlaces(name: String, rendition: String, tones: [Double?]) async throws {
        // The second segment, which starts in the middle of the stream.
        let segment = try #require(try await Self.segments(of: rendition, from: name) { _ in [1] }.segments.first)

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
    /// The whole decode drops what the file marks as the codec's: its priming at the start and
    /// its padding at the end. The delivery drops the priming and keeps the padding (`padding`
    /// sample frames past the stream's end). Where the audio then starts after the first
    /// picture, the delivery starts it there with silence (`lead` sample frames): a sample after
    /// it for MP3 and MP2.
    ///
    /// `vorbis-bursts` is libvorbis's encode of a tone with bursts of noise, where its frames
    /// change length, and the frame after a change is timed 9 ms from where its samples are.
    /// `mp3-44k` has frames of 26.122 ms timed to the millisecond, after a first one of 47
    /// samples: a segment that places its frames by their times alone is two samples off.
    @Test("a lossy track's segments hold what one decode of the whole stream gives, to within two steps of the depth its decoder gives, each segment starting where the one before ends", arguments: [
        ("mp3", "a0", 1, 24, 431, 1), ("mp2", "a0", 1, 16, 0, 1), ("vorbis", "a0", 1, 24, 512, 0),
        ("vorbis-bursts", "a0", 1, 24, 0, 0), ("wma", "a0", 1, 24, 0, 0), ("ac3-dts-51", "a1", 2, 24, 256, 0),
        ("mp3-44k", "a0", 1, 24, 407, 0), ("ts-mp2.ts", "a0", 1, 16, 0, 0),
    ])
    func lossyTrackMatchesOneDecodeOfTheStream(
        name: String, rendition: String, stream: Int, bits: Int, padding: Int, lead: Int
    ) async throws {
        let segments = try await Self.segments(of: rendition, from: name).segments
        let channels = try #require(segments.first?.channelCount)
        let whole = try Self.decodedWhole(name, stream: stream)

        let delivered = segments.flatMap(\.samples)
        #expect(delivered.prefix(lead * channels).allSatisfy { $0 == 0 }, "\(delivered.prefix(lead * channels))")
        let converted = delivered.dropFirst(lead * channels)
        #expect(
            converted.count == whole.count + padding * channels,
            "\(segments.map(\.frameCount)) at \(segments.map(\.start)), whole \(whole.count / channels)")
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
        let segments = try await Self.segments(of: "a0", from: "pcm-uneven").segments

        let frames = segments.map(\.frameCount).reduce(0, +)
        #expect(abs(frames - 36_288) <= 8, "\(frames) sample frames")
    }

    @Test("where a stream has no packets for a while, its segments hold silence and keep their length")
    func holeInTheStreamIsSilence() async throws {
        // A 440 Hz tone at 48 kHz with nothing from 1.502 s to 2.702 s, across the join at 2 s.
        // Its first packet is at -10 ms, and the first 10.02 ms it decodes to are the codec's
        // priming, so its first sample is at 0.02 ms, and the first segment starts with a
        // sample of silence at the first picture, at 0 s.
        let segments = try await Self.segments(of: "a0", from: "mp2-hole").segments
        func sample(atMilliseconds time: Int) -> Int { time * 48 }

        try #require(segments.count == 2)
        #expect(segments[1].start - segments[0].start == Int64(sample(atMilliseconds: 2000)))
        #expect(segments[1].start - segments[0].start == Int64(segments[0].frameCount))
        let samples = segments.flatMap { $0.channel(0) }
        try #require(samples.count >= 160_000, "\(samples.count) samples")
        // The container times a frame to the millisecond: 48 samples.
        let hole = sample(atMilliseconds: 1502) + 48 ..< sample(atMilliseconds: 2702) - 48
        #expect(samples[hole].allSatisfy { $0 == 0 })
        // Half a second on either side, clear of the frames next to the hole.
        for tone in [samples[40_000..<64_000], samples[136_000..<160_000]] {
            #expect(Self.share(of: 440, in: tone.map(Double.init)) > 0.9)
        }
    }

    /// Every sample libavcodec decodes from `stream` of a fixture that libavformat reads whole,
    /// as 32-bit integers the way libswresample widens them, every channel of a sample frame
    /// in a row in the decoder's order: the reading the converted segments are held to.
    private static func decodedWhole(_ name: String, stream index: Int) throws -> [Int32] {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension(name.contains(".") ? String(name.split(separator: ".")[1]) : "mkv")
        try BridgeFixture.data(name).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        var format: UnsafeMutablePointer<AVFormatContext>?
        guard avformat_open_input(&format, url.path, nil, nil) >= 0, let format else { throw ReadbackFailure(code: -1) }
        defer {
            var format: UnsafeMutablePointer<AVFormatContext>? = format
            avformat_close_input(&format)
        }
        try Self.check(avformat_find_stream_info(format, nil))
        let parameters = try #require(format.pointee.streams[index]?.pointee.codecpar)
        let codec = try #require(avcodec_find_decoder(parameters.pointee.codec_id))
        var context = avcodec_alloc_context3(codec)
        defer { avcodec_free_context(&context) }
        let decoder = try #require(context)
        try Self.check(avcodec_parameters_to_context(decoder, parameters))
        decoder.pointee.pkt_timebase = format.pointee.streams[index]!.pointee.time_base
        try Self.check(avcodec_open2(decoder, codec, nil))

        var packet = av_packet_alloc(), frame = av_frame_alloc()
        defer {
            av_packet_free(&packet)
            av_frame_free(&frame)
        }
        var samples: [Int32] = []
        func receive() {
            while avcodec_receive_frame(decoder, frame) >= 0 {
                samples += Self.widened(frame!)
                av_frame_unref(frame)
            }
        }
        while av_read_frame(format, packet) >= 0 {
            if packet!.pointee.stream_index == Int32(index), avcodec_send_packet(decoder, packet) >= 0 { receive() }
            av_packet_unref(packet)
        }
        if avcodec_send_packet(decoder, nil) >= 0 { receive() }
        return samples
    }

    /// libswresample's conversions to 32 bits: a float times 2³¹ rounded to the nearest, ties
    /// to even, and 16 bits shifted to the top.
    private static func widened(_ frame: UnsafeMutablePointer<AVFrame>) -> [Int32] {
        let channels = Int(frame.pointee.ch_layout.nb_channels), count = Int(frame.pointee.nb_samples)
        let format = AVSampleFormat(frame.pointee.format)
        let isPlanar = av_sample_fmt_is_planar(format) != 0
        let packed = av_get_packed_sample_fmt(format)
        return (0..<count * channels).map { place in
            let (channel, index) = (place % channels, place / channels)
            let plane = frame.pointee.extended_data[isPlanar ? channel : 0]!
            let at = isPlanar ? index : place
            switch packed {
            case AV_SAMPLE_FMT_FLT:
                let value = plane.withMemoryRebound(to: Float.self, capacity: at + 1) { $0[at] }
                return Int32(clamping: Int64((Double(value) * 2_147_483_648).rounded(.toNearestOrEven)))
            case AV_SAMPLE_FMT_S16:
                return Int32(plane.withMemoryRebound(to: Int16.self, capacity: at + 1) { $0[at] }) << 16
            case AV_SAMPLE_FMT_S32:
                return plane.withMemoryRebound(to: Int32.self, capacity: at + 1) { $0[at] }
            default:
                Issue.record("sample format \(format.rawValue)")
                return 0
            }
        }
    }

    private static func check(_ status: Int32) throws {
        if status < 0 { throw ReadbackFailure(code: status) }
    }
}
