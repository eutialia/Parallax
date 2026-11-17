import AetherLibavcodec
import AetherLibavutil
import Foundation

/// Encodes sample frames as FLAC, 24 bits a sample, losing nothing.
///
/// An encoder is made for each segment. A FLAC frame stands alone, so the frames of two
/// encoders decode as one stream.
///
/// Lives on one thread: the demuxer's queue that reads the segment.
final class FLACEncoder {
    enum Failure: Error, Equatable {
        case outOfMemory
        case noEncoder
        case encoder(code: Int32)
    }

    /// The stream as the MP4 muxer describes it: FLAC, with the encoder's STREAMINFO.
    let parameters: CodecParameters

    private let context: UnsafeMutablePointer<AVCodecContext>
    private let frame: UnsafeMutablePointer<AVFrame>
    private let packet: UnsafeMutablePointer<AVPacket>
    private let channelCount: Int
    private let samplesPerFrame: Int
    /// Samples not yet a whole frame.
    private var waiting: [Int32] = []
    private var framesSent: Int64 = 0

    init(sampleRate: Int, channelCount: Int) throws(Failure) {
        guard let codec = avcodec_find_encoder(AV_CODEC_ID_FLAC) else { throw .noEncoder }
        var context = avcodec_alloc_context3(codec)
        guard let allocated = context else { throw .outOfMemory }
        allocated.pointee.sample_rate = Int32(sampleRate)
        allocated.pointee.sample_fmt = AV_SAMPLE_FMT_S32
        allocated.pointee.bits_per_raw_sample = 24
        av_channel_layout_default(&allocated.pointee.ch_layout, Int32(channelCount))
        allocated.pointee.time_base = AVRational(num: 1, den: Int32(sampleRate))
        // The STREAMINFO goes into the sample entry, not in front of the first frame.
        allocated.pointee.flags |= AV_CODEC_FLAG_GLOBAL_HEADER
        let status = avcodec_open2(allocated, codec, nil)
        var frame = av_frame_alloc(), packet = av_packet_alloc()
        guard status >= 0, let frame, let packet, let parameters = CodecParameters(of: allocated) else {
            av_frame_free(&frame)
            av_packet_free(&packet)
            avcodec_free_context(&context)
            throw status < 0 ? .encoder(code: status) : .outOfMemory
        }
        self.context = allocated
        self.frame = frame
        self.packet = packet
        self.parameters = parameters
        self.channelCount = channelCount
        samplesPerFrame = Int(allocated.pointee.frame_size)
    }

    deinit {
        var frame: UnsafeMutablePointer<AVFrame>? = frame, packet: UnsafeMutablePointer<AVPacket>? = packet
        av_frame_free(&frame)
        av_packet_free(&packet)
        var context: UnsafeMutablePointer<AVCodecContext>? = context
        avcodec_free_context(&context)
    }

    /// `take` is handed each FLAC frame the samples complete, with the sample frames it holds.
    func encode(_ samples: some Collection<Int32>, into take: (Data, _ length: Int64) throws -> Void) throws {
        waiting.append(contentsOf: samples)
        let whole = samplesPerFrame * channelCount
        var sent = 0
        while waiting.count - sent >= whole {
            try send(waiting[sent..<sent + whole], into: take)
            sent += whole
        }
        waiting.removeFirst(sent)
    }

    /// The samples left over as one short frame.
    func finish(into take: (Data, _ length: Int64) throws -> Void) throws {
        if !waiting.isEmpty { try send(waiting[...], into: take) }
        waiting = []
        try check(avcodec_send_frame(context, nil))
        try receive(into: take)
    }

    private func send(_ samples: ArraySlice<Int32>, into take: (Data, _ length: Int64) throws -> Void) throws {
        let count = samples.count / channelCount
        frame.pointee.nb_samples = Int32(count)
        frame.pointee.format = AV_SAMPLE_FMT_S32.rawValue
        frame.pointee.sample_rate = context.pointee.sample_rate
        try check(av_channel_layout_copy(&frame.pointee.ch_layout, &context.pointee.ch_layout))
        try check(av_frame_get_buffer(frame, 0))
        defer { av_frame_unref(frame) }
        samples.withUnsafeBytes { UnsafeMutableRawPointer(frame.pointee.data.0)?.copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
        frame.pointee.pts = framesSent
        framesSent += Int64(count)
        try check(avcodec_send_frame(context, frame))
        try receive(into: take)
    }

    private func receive(into take: (Data, _ length: Int64) throws -> Void) throws {
        while avcodec_receive_packet(context, packet) >= 0 {
            defer { av_packet_unref(packet) }
            // When it ends, the encoder sends an empty packet that only carries the STREAMINFO
            // again, and the MP4 muxer fails a sample with no bytes.
            guard packet.pointee.size > 0, let bytes = packet.pointee.data else { continue }
            try take(Data(bytes: bytes, count: Int(packet.pointee.size)), packet.pointee.duration)
        }
    }

    private func check(_ status: Int32) throws(Failure) {
        if status < 0 { throw .encoder(code: status) }
    }
}
