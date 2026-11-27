import AetherLibavcodec
import AetherLibavutil
import AetherLibswresample
import Foundation

/// What a decoder made of one packet: whole sample frames, every channel of a frame in a row.
struct DecodedAudio {
    /// Nanoseconds, as the packet was timed. Nil for a packet the container gave no time.
    let time: Int64?
    /// 24 bits in the top of each 32, in FLAC's channel order for `channelCount`.
    let samples: [Int32]
    let channelCount: Int
    let sampleRate: Int

    var frameCount: Int { samples.count / channelCount }
}

/// Decodes one audio stream's packets through libavcodec.
///
/// Lives on one thread: the demuxer's queue that reads the segment.
final class AudioDecoder {
    enum Failure: Error, Equatable {
        case outOfMemory
        case noDecoder
        case decoder(code: Int32)
    }

    private let context: UnsafeMutablePointer<AVCodecContext>
    private let packet: UnsafeMutablePointer<AVPacket>
    private let frame: UnsafeMutablePointer<AVFrame>
    private var resampler: OpaquePointer?
    /// What the resampler was opened for. A stream may change any of them on the way.
    private var resampled: (format: Int32, channelCount: Int, sampleRate: Int)?

    /// Whether this build of libavcodec has a decoder for the stream.
    static func decodes(_ parameters: CodecParameters) -> Bool {
        avcodec_find_decoder(parameters.pointer.pointee.codec_id) != nil
    }

    init(_ parameters: CodecParameters) throws(Failure) {
        guard let codec = avcodec_find_decoder(parameters.pointer.pointee.codec_id) else { throw .noDecoder }
        var context = avcodec_alloc_context3(codec)
        guard let allocated = context else { throw .outOfMemory }
        var packet = av_packet_alloc(), frame = av_frame_alloc()
        guard let packet, let frame else {
            av_packet_free(&packet)
            av_frame_free(&frame)
            avcodec_free_context(&context)
            throw .outOfMemory
        }
        var status = avcodec_parameters_to_context(allocated, parameters.pointer)
        // Packets are handed over timed in nanoseconds.
        allocated.pointee.pkt_timebase = AVRational(num: 1, den: 1_000_000_000)
        if status >= 0 { status = avcodec_open2(allocated, codec, nil) }
        guard status >= 0 else {
            var packet: UnsafeMutablePointer<AVPacket>? = packet, frame: UnsafeMutablePointer<AVFrame>? = frame
            av_packet_free(&packet)
            av_frame_free(&frame)
            avcodec_free_context(&context)
            throw .decoder(code: status)
        }
        self.context = allocated
        self.packet = packet
        self.frame = frame
    }

    deinit {
        swr_free(&resampler)
        var packet: UnsafeMutablePointer<AVPacket>? = packet, frame: UnsafeMutablePointer<AVFrame>? = frame
        av_packet_free(&packet)
        av_frame_free(&frame)
        var context: UnsafeMutablePointer<AVCodecContext>? = context
        avcodec_free_context(&context)
    }

    /// What the decoder gives for `source`, which may be nothing, or what an earlier packet
    /// held. A packet the decoder refuses is passed over: a damaged frame, or the first of a
    /// read that starts where the stream cannot.
    func decode(_ source: MediaPacket, into take: (DecodedAudio) throws -> Void) throws {
        guard av_new_packet(packet, Int32(source.data.count)) >= 0 else { throw Failure.outOfMemory }
        defer { av_packet_unref(packet) }
        source.data.copyBytes(to: packet.pointee.data, count: source.data.count)
        packet.pointee.pts = source.presentationTime ?? Self.noTime
        packet.pointee.dts = packet.pointee.pts
        if source.isKeyframe { packet.pointee.flags |= AV_PKT_FLAG_KEY }
        if source.primingSamples > 0 { try Self.skip(source.primingSamples, of: packet) }
        guard avcodec_send_packet(context, packet) >= 0 else { return }
        try receive(into: take)
    }

    /// Has the decoder drop the first `samples` of what `packet` decodes to. The padding a
    /// container marks at the end is kept, by decision: 5 to 11 ms.
    private static func skip(_ samples: Int, of packet: UnsafeMutablePointer<AVPacket>) throws(Failure) {
        // Samples skipped at the start, then padding discarded at the end, as little-endian
        // 32-bit counts, then a byte of reason for each.
        let side = withUnsafeBytes(of: UInt32(samples).littleEndian, Array.init) + [UInt8](repeating: 0, count: 6)
        guard let data = av_packet_new_side_data(packet, AV_PKT_DATA_SKIP_SAMPLES, side.count) else { throw .outOfMemory }
        data.update(from: side, count: side.count)
    }

    /// What the decoder still holds, when the stream has no more packets.
    func finish(into take: (DecodedAudio) throws -> Void) throws {
        guard avcodec_send_packet(context, nil) >= 0 else { return }
        try receive(into: take)
    }

    private func receive(into take: (DecodedAudio) throws -> Void) throws {
        while avcodec_receive_frame(context, frame) >= 0 {
            defer { av_frame_unref(frame) }
            if let decoded = try interleaved() { try take(decoded) }
        }
    }

    private func interleaved() throws(Failure) -> DecodedAudio? {
        let rate = Int(frame.pointee.sample_rate), channels = Int(frame.pointee.ch_layout.nb_channels)
        let count = Int(frame.pointee.nb_samples)
        guard rate > 0, channels > 0, count > 0 else { return nil }
        let format = (frame.pointee.format, channels, rate)
        if resampled.map({ $0 != format }) ?? true {
            try openResampler(channels: Int32(channels), rate: Int32(rate))
            resampled = format
        }

        var samples = [Int32](repeating: 0, count: count * channels)
        let converted = samples.withUnsafeMutableBufferPointer { buffer in
            buffer.baseAddress!.withMemoryRebound(to: UInt8.self, capacity: buffer.count * 4) { bytes in
                var output: UnsafeMutablePointer<UInt8>? = bytes
                return withUnsafeMutablePointer(to: &output) { output in
                    frame.pointee.extended_data.withMemoryRebound(to: UnsafePointer<UInt8>?.self, capacity: channels) {
                        swr_convert(resampler, output, Int32(count), $0, Int32(count))
                    }
                }
            }
        }
        guard converted == count else { throw .decoder(code: converted) }
        let time = frame.pointee.pts == Self.noTime ? nil : frame.pointee.pts
        guard let places = Self.flacPlaces(of: frame.pointee.ch_layout) else {
            return DecodedAudio(time: time, samples: samples, channelCount: channels, sampleRate: rate)
        }
        var placed = [Int32](repeating: 0, count: count * places.channelCount)
        for (channel, place) in places.ofEachChannel.enumerated() {
            for index in 0..<count { placed[index * places.channelCount + place] = samples[index * channels + channel] }
        }
        return DecodedAudio(time: time, samples: placed, channelCount: places.channelCount, sampleRate: rate)
    }

    /// The sets of speakers FLAC has, one or two for each channel count, fewest channels first,
    /// as libavutil's speaker bits: mono, stereo, 3.0, quad, 5.0 with side or back surrounds,
    /// 5.1 the same, 6.1 and 7.1. A set's channels are in the order of its bits.
    private static let flacSpeakers: [UInt64] = [0x4, 0x3, 0x7, 0x33, 0x607, 0x37, 0x60F, 0x3F, 0x70F, 0x63F]

    /// Where each of the layout's channels goes in the smallest of FLAC's sets that holds its
    /// speakers: a 2.1 track's subwoofer is the fourth channel of 5.1. Nil for a layout that is
    /// one of FLAC's, whose channels stay where they are, and for one no set of FLAC's holds
    /// or that names no speakers, where nothing better is known.
    private static func flacPlaces(of layout: AVChannelLayout) -> (channelCount: Int, ofEachChannel: [Int])? {
        guard layout.order == AV_CHANNEL_ORDER_NATIVE, case let speakers = layout.u.mask,
              !flacSpeakers.contains(speakers), let set = flacSpeakers.first(where: { $0 & speakers == speakers })
        else { return nil }
        let places = (0..<UInt64.bitWidth).filter { speakers >> UInt64($0) & 1 == 1 }.map {
            (set & (1 << UInt64($0) - 1)).nonzeroBitCount
        }
        return (set.nonzeroBitCount, places)
    }

    /// Only the sample format is converted: the channels stay as many, in the order decoded.
    /// swresample could also move them, but it mixes when it does, and a lossless track would
    /// no longer be exact.
    private func openResampler(channels: Int32, rate: Int32) throws(Failure) {
        swr_free(&resampler)
        var layout = AVChannelLayout()
        av_channel_layout_default(&layout, channels)
        defer { av_channel_layout_uninit(&layout) }
        var status = swr_alloc_set_opts2(
            &resampler, &layout, AV_SAMPLE_FMT_S32, rate, &layout, AVSampleFormat(frame.pointee.format), rate, 0, nil)
        if status >= 0 { status = swr_init(resampler) }
        guard status >= 0 else { throw .decoder(code: status) }
    }

    /// `AV_NOPTS_VALUE`, which does not import into Swift.
    private static let noTime = Int64.min
}
