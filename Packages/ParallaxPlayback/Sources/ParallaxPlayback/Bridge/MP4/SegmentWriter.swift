import AetherLibavcodec
import AetherLibavformat
import AetherLibavutil
import Foundation

/// Writes one rendition's packets as fragmented MP4 through libavformat's muxer. Nothing is
/// decoded: every sample is the container's bytes.
enum SegmentWriter {
    enum Failure: Error, Equatable {
        case outOfMemory
        /// The span holds no packet of this rendition, so there is nothing to describe or play.
        case noSamples
        /// A sample the container gives no time. Guessing one would play it at the wrong moment.
        case untimedSample
        case muxer(code: Int32)
        /// The muxer took the samples and wrote no fragment.
        case noFragment
    }

    /// The `ftyp` and `moov` of the rendition. libavformat describes some codecs from their
    /// first frames, so it needs packets of the rendition: any span's will do.
    static func initSegment(for rendition: Rendition, describedBy packets: [DemuxedPacket]) throws(Failure) -> Data {
        let written = try write(rendition, packets)
        return Data(written.bytes[..<written.fragmentStart])
    }

    /// One `moof` and `mdat` holding `packets`, which are one span's packets of the rendition
    /// in file order.
    ///
    /// With `end`, the source time the segment runs to, a rendition whose samples stop short of
    /// it still lasts until it: the last sample is lengthened. AVPlayer ends an item where its
    /// shortest rendition ends, so audio that stops a second before the video would cut that
    /// second of video off.
    static func mediaSegment(
        for rendition: Rendition, packets: [DemuxedPacket], lastingUntil end: Int64? = nil
    ) throws(Failure) -> Data {
        let written = try write(rendition, packets, lastingUntil: end)
        return Data(written.bytes[written.fragmentStart...])
    }

    /// Times are in the rendition's ticks.
    private struct Sample {
        let packet: DemuxedPacket
        let presentation: Int64
        let decode: Int64
        let duration: Int64
    }

    /// Decode order is file order. A decode time is the sample's rank among the span's
    /// presentation times, less the rendition's lead, so it needs nothing from outside the span.
    private static func samples(
        _ rendition: Rendition, _ packets: [DemuxedPacket], _ end: Int64?
    ) throws(Failure) -> [Sample] {
        guard !packets.isEmpty else { throw .noSamples }
        var presentation: [Int64] = []
        for packet in packets {
            guard let time = packet.presentationTime else { throw .untimedSample }
            presentation.append(rendition.clock.ticks(at: time))
        }
        let last = presentation.max()
        return zip(packets, zip(presentation, presentation.sorted())).map { packet, times in
            let duration = rendition.clock.grid?.step
                ?? packet.duration.map { $0 * rendition.clock.timescale / 1_000_000_000 } ?? 0
            // Samples of neighboring segments meet within one sample's length. A wider gap
            // means the rendition stopped.
            let gap = end.map { rendition.clock.ticks(at: $0) - times.0 - duration } ?? 0
            return Sample(
                packet: packet, presentation: times.0, decode: times.1 - rendition.decodeLead,
                duration: times.0 == last && gap > duration ? duration + gap : duration)
        }
    }

    private static func write(
        _ rendition: Rendition, _ packets: [DemuxedPacket], lastingUntil end: Int64? = nil
    ) throws(Failure) -> (bytes: Data, fragmentStart: Int) {
        let samples = try samples(rendition, packets, end)

        var allocated: UnsafeMutablePointer<AVFormatContext>?
        try check(avformat_alloc_output_context2(&allocated, nil, "mp4", nil))
        guard let context = allocated else { throw .outOfMemory }
        defer { avformat_free_context(context) }
        // The muxer writes the Dolby Vision record into the sample entry only past official
        // compliance, and only where the playlist names the layer.
        if rendition.supplementalCodec != nil {
            context.pointee.strict_std_compliance = FF_COMPLIANCE_UNOFFICIAL
        }

        guard let stream = avformat_new_stream(context, nil) else { throw .outOfMemory }
        try check(avcodec_parameters_copy(stream.pointee.codecpar, rendition.stream.parameters.pointer))
        // The sample entry the playlist declared: the codec string's first four characters.
        // Left to itself the muxer stores HEVC as `hev1`, which AVPlayer does not play.
        stream.pointee.codecpar.pointee.codec_tag = rendition.codec.utf8.prefix(4).reversed()
            .reduce(0) { $0 << 8 | UInt32($1) }
        if rendition.stream.kind == .audio, let frame = rendition.clock.grid?.step {
            stream.pointee.codecpar.pointee.frame_size = Int32(frame)
        }
        let timescale = AVRational(num: 1, den: Int32(rendition.clock.timescale))
        stream.pointee.time_base = timescale

        try check(avio_open_dyn_buf(&context.pointee.pb))
        defer {
            var buffer: UnsafeMutablePointer<UInt8>?
            avio_close_dyn_buf(context.pointee.pb, &buffer)
            av_free(buffer)
            context.pointee.pb = nil
        }

        var options: OpaquePointer?
        defer { av_dict_free(&options) }
        av_dict_set(&options, "movflags", Self.flags, 0)
        av_dict_set(&options, "video_track_timescale", "\(rendition.clock.timescale)", 0)
        try check(avformat_write_header(context, &options))

        guard let packet = av_packet_alloc() else { throw .outOfMemory }
        defer {
            var packet: UnsafeMutablePointer<AVPacket>? = packet
            av_packet_free(&packet)
        }
        for sample in samples {
            try check(av_new_packet(packet, Int32(sample.packet.data.count)))
            defer { av_packet_unref(packet) }
            sample.packet.data.copyBytes(to: packet.pointee.data, count: sample.packet.data.count)
            packet.pointee.stream_index = 0
            packet.pointee.pts = av_rescale_q(sample.presentation, timescale, stream.pointee.time_base)
            packet.pointee.dts = av_rescale_q(sample.decode, timescale, stream.pointee.time_base)
            packet.pointee.duration = av_rescale_q(sample.duration, timescale, stream.pointee.time_base)
            if sample.packet.isKeyframe { packet.pointee.flags |= AV_PKT_FLAG_KEY }
            try check(av_write_frame(context, packet))
        }
        // A null packet flushes. With `delay_moov` the first flush writes the `moov` the packets
        // described, and the second writes them as a fragment.
        try check(av_write_frame(context, nil))
        try check(av_write_frame(context, nil))
        avio_flush(context.pointee.pb)

        var buffer: UnsafeMutablePointer<UInt8>?
        let size = avio_get_dyn_buf(context.pointee.pb, &buffer)
        guard let buffer, size > 0 else { throw .noFragment }
        var bytes = Data(bytes: buffer, count: Int(size))
        guard let fragmentStart = offsetOfBox("moof", in: bytes) else { throw .noFragment }
        try redate(&bytes, fragmentAt: fragmentStart, samples)
        return (bytes, fragmentStart)
    }

    /// With an edit list and `frag_discont`, the muxer dates a fragment by its first sample's
    /// presentation time, and the edit list takes the rendition's lead off it. That holds where
    /// the first sample decoded is the first shown. A later open-GOP keyframe is shown after
    /// pictures it decodes before, and its fragment would play late by them, so the fragment
    /// is dated by its earliest presentation time instead.
    private static func redate(_ bytes: inout Data, fragmentAt moof: Int, _ samples: [Sample]) throws(Failure) {
        guard let traf = offsetOfBox("traf", in: bytes, inside: moof),
              let tfdt = offsetOfBox("tfdt", in: bytes, inside: traf),
              // Version 1: a 64-bit decode time after the header, version and flags.
              bytes[bytes.startIndex + tfdt + 8] == 1,
              let earliest = samples.map(\.presentation).min(), earliest >= 0
        else { throw .noFragment }
        let time = bytes.startIndex + tfdt + 12
        bytes.replaceSubrange(time..<time + 8, with: withUnsafeBytes(of: UInt64(earliest).bigEndian) { Data($0) })
    }

    private static let flags = "frag_custom+delay_moov+default_base_moof+frag_discont"

    /// The offset of the first box of `type` at the top level, or among the children of the box
    /// at `parent`.
    private static func offsetOfBox(_ type: String, in bytes: Data, inside parent: Int? = nil) -> Int? {
        let end = parent.map { $0 + bytes[bytes.startIndex + $0..<bytes.startIndex + $0 + 4].reduce(0) { $0 << 8 | Int($1) } }
            ?? bytes.count
        var offset = parent.map { $0 + 8 } ?? 0
        while offset + 8 <= min(end, bytes.count) {
            let header = bytes[bytes.startIndex + offset..<bytes.startIndex + offset + 8]
            let size = header.prefix(4).reduce(0) { $0 << 8 | Int($1) }
            if String(decoding: header.suffix(4), as: UTF8.self) == type { return offset }
            guard size >= 8 else { return nil }
            offset += size
        }
        return nil
    }

    private static func check(_ status: Int32) throws(Failure) {
        if status < 0 { throw .muxer(code: status) }
    }
}
