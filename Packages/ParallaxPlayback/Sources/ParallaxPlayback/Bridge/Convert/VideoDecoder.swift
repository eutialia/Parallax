import AetherLibavcodec
import AetherLibavutil
import Foundation

/// Decodes one video stream's packets through libavcodec, in software. A stream stored as
/// fields comes out as a whole picture for each field.
///
/// Lives on one thread: the demuxer's queue that reads the segment.
final class VideoDecoder {
    enum Failure: Error, Equatable {
        case outOfMemory
        case noDecoder
        case decoder(code: Int32)
        case deinterlacer(code: Int32)
    }

    private let context: UnsafeMutablePointer<AVCodecContext>
    private let packet: UnsafeMutablePointer<AVPacket>
    private let frame: UnsafeMutablePointer<AVFrame>
    private let isInterlaced: Bool
    private let timedByDecodeOrder: Bool
    /// The decode times of the packets handed over so far, for `timedByDecodeOrder`.
    private var decodeTimes: [Int64] = []
    private var deinterlacer: Deinterlacer?

    /// Whether this build of libavcodec has a software decoder for the stream.
    static func decodes(_ parameters: CodecParameters) -> Bool {
        codec(for: parameters) != nil
    }

    /// libavcodec's own AV1 decoder only drives a hardware one, so AV1 goes to dav1d.
    private static func codec(for parameters: CodecParameters) -> UnsafePointer<AVCodec>? {
        let id = parameters.pointer.pointee.codec_id
        return id == AV_CODEC_ID_AV1 ? avcodec_find_decoder_by_name("libdav1d") : avcodec_find_decoder(id)
    }

    /// With `timedByDecodeOrder`, the packets' times are decode times and no packet says when
    /// its picture shows. A decoder that holds back one picture (`holdsBackOnePicture`) gives
    /// each picture as it is handed the packet stored after the last one shown before it, so
    /// a picture shows at the decode time of the packet before the one that brought it out.
    init(_ parameters: CodecParameters, timedByDecodeOrder: Bool) throws(Failure) {
        guard let codec = Self.codec(for: parameters) else { throw .noDecoder }
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
        // As many threads as the device has cores.
        allocated.pointee.thread_count = 0
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
        isInterlaced = parameters.isInterlaced
        self.timedByDecodeOrder = timedByDecodeOrder
    }

    deinit {
        var packet: UnsafeMutablePointer<AVPacket>? = packet, frame: UnsafeMutablePointer<AVFrame>? = frame
        av_packet_free(&packet)
        av_frame_free(&frame)
        var context: UnsafeMutablePointer<AVCodecContext>? = context
        avcodec_free_context(&context)
    }

    /// The pictures the decoder gives for `source`, in the order they are shown, each timed
    /// in nanoseconds in `pts`. A stream of fields gives each frame's two pictures one frame
    /// late, the second timed halfway to the next frame. It may give none, or ones earlier packets held. A
    /// picture is `take`'s only for the call. A packet the decoder refuses is passed over: a
    /// damaged picture, or one that needs pictures from before the read started.
    func decode(_ source: MediaPacket, into take: (UnsafePointer<AVFrame>) throws -> Void) throws {
        guard av_new_packet(packet, Int32(source.data.count)) >= 0 else { throw Failure.outOfMemory }
        defer { av_packet_unref(packet) }
        source.data.copyBytes(to: packet.pointee.data, count: source.data.count)
        if timedByDecodeOrder {
            packet.pointee.pts = Self.noTime
            packet.pointee.dts = source.presentationTime ?? Self.noTime
            if let time = source.presentationTime { decodeTimes.append(time) }
        } else {
            packet.pointee.pts = source.presentationTime ?? Self.noTime
            // The decoder times a picture whose packet has no presentation time from this.
            packet.pointee.dts = source.decodeTime ?? Self.noTime
        }
        if source.isKeyframe { packet.pointee.flags |= AV_PKT_FLAG_KEY }
        guard avcodec_send_packet(context, packet) >= 0 else { return }
        try receive(into: take)
    }

    /// The pictures the decoder still holds, when the stream has no more packets.
    func finish(into take: (UnsafePointer<AVFrame>) throws -> Void) throws {
        if avcodec_send_packet(context, nil) >= 0 { try receive(into: take) }
        try deinterlacer?.finish(into: take)
    }

    private func receive(into take: (UnsafePointer<AVFrame>) throws -> Void) throws {
        while avcodec_receive_frame(context, frame) >= 0 {
            defer { av_frame_unref(frame) }
            if timedByDecodeOrder {
                // The last pictures come out with no packet behind them.
                let broughtOutBy = frame.pointee.pkt_dts
                frame.pointee.pts = (broughtOutBy == Self.noTime
                    ? decodeTimes.last : decodeTimes.last { $0 < broughtOutBy }) ?? Self.noTime
            } else if frame.pointee.pts == Self.noTime {
                frame.pointee.pts = frame.pointee.best_effort_timestamp
            }
            guard isInterlaced else {
                try take(frame)
                continue
            }
            if let deinterlacer, deinterlacer.takes(frame) {
                try deinterlacer.push(frame, into: take)
            } else {
                // The stream changed size: the filter still holds the last frame of the old one.
                try deinterlacer?.finish(into: take)
                let made = try Deinterlacer(for: frame)
                deinterlacer = made
                try made.push(frame, into: take)
            }
        }
    }

    /// `AV_NOPTS_VALUE`, which does not import into Swift.
    static let noTime = Int64.min
}
