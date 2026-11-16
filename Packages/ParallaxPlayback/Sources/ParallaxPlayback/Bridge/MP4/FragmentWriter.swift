import AetherLibavcodec
import AetherLibavformat
import AetherLibavutil
import Foundation

/// Where a segment's fragments close: at the first sample past either limit.
struct FragmentLimits: Sendable {
    /// Of sample bytes.
    let bytes: Int
    /// Of summed sample durations.
    let duration: Duration

    static let standard = FragmentLimits(bytes: 2 << 20, duration: .seconds(1))
    /// One fragment for the whole segment.
    static let whole = FragmentLimits(bytes: .max, duration: .seconds(Int64.max))
}

/// Writes one segment of a rendition as fragmented MP4 through libavformat's muxer, fragment by
/// fragment as its packets arrive. Nothing is decoded: every sample is the container's bytes.
///
/// Decode order is file order. A sample's decode time is its rank among the segment's
/// presentation times, less the rendition's lead, so a segment needs nothing from outside
/// itself. The rank is known once the stream's reorder depth has passed: a sample is written
/// when `lookahead` packets have arrived after it, and takes the smallest presentation time
/// not yet given out.
///
/// The muxer joins short E-AC-3 frames into one MP4 sample and holds them until the sample is
/// whole, so a fragment closes only after a whole sample, and the frames of an unfinished last
/// one are left out.
///
/// Lives on one thread: the demuxer's queue that reads the segment.
final class FragmentWriter {
    /// The `ftyp` and `moov` the muxer wrote before the first fragment.
    private(set) var header: Data?

    private let rendition: Rendition
    private let end: Int64?
    private let byteLimit: Int
    private let tickLimit: Double
    /// Packets that arrive after a sample before it is written.
    let lookahead: Int
    private let framesPerSample: Int
    private let context: UnsafeMutablePointer<AVFormatContext>
    private let packet: UnsafeMutablePointer<AVPacket>
    /// Takes the ADTS header off each AAC frame and hands the muxer the configuration record
    /// the header stands for. Nil for a stream whose container gave it a record. The MP4 muxer
    /// of FFmpegBuild 3.14.0 does not do this itself: it fails the frame as a malformed AAC
    /// bitstream.
    private let adtsFilter: UnsafeMutablePointer<AVBSFContext>?
    private let timescale: AVRational
    private let timeBase: AVRational

    /// In decode order, with their presentation times in the rendition's ticks.
    private var waiting: [(packet: DemuxedPacket, presentation: Int64)] = []
    /// Presentation times not yet given out as decode times, smallest first.
    private var unassigned: [Int64] = []
    private var lastAssigned = Int64.min
    /// The decode time the fragment's first sample took, before the lead is taken off.
    private var fragmentStart: Int64?
    private var fragmentBytes = 0
    private var fragmentTicks: Int64 = 0
    private var framesWritten = 0
    private var wroteFragment = false

    /// `end`, the source time the segment runs to, makes a rendition whose samples stop short of
    /// it still last until it: the last sample is lengthened. AVPlayer ends an item where its
    /// shortest rendition ends, so audio that stops a second before the video would cut that
    /// second of video off.
    init(_ rendition: Rendition, lastingUntil end: Int64? = nil, limits: FragmentLimits) throws(SegmentWriter.Failure) {
        var allocated: UnsafeMutablePointer<AVFormatContext>?
        try SegmentWriter.check(avformat_alloc_output_context2(&allocated, nil, "mp4", nil))
        guard let context = allocated else { throw .outOfMemory }
        guard let packet = av_packet_alloc() else {
            avformat_free_context(context)
            throw .outOfMemory
        }
        let muxed: AVRational
        do throws(SegmentWriter.Failure) {
            muxed = try Self.writeHeader(of: rendition, into: context)
            adtsFilter = rendition.stream.parameters.hasADTSHeaders
                ? try Self.adtsFilter(for: rendition.stream.parameters) : nil
        } catch {
            var packet: UnsafeMutablePointer<AVPacket>? = packet
            av_packet_free(&packet)
            Self.closeBuffer(of: context)
            avformat_free_context(context)
            throw error
        }
        self.rendition = rendition
        self.end = end
        self.context = context
        self.packet = packet
        byteLimit = limits.bytes
        tickLimit = limits.duration / .seconds(1) * Double(rendition.clock.timescale)
        framesPerSample = Int(rendition.clock.grid?.framesPerSample ?? 1)
        // At least an unfinished sample's frames still wait at the end, where they are left out.
        lookahead = max(rendition.stream.parameters.reorderDepth + 4, framesPerSample)
        timescale = AVRational(num: 1, den: Int32(rendition.clock.timescale))
        timeBase = muxed
    }

    deinit {
        var adtsFilter = adtsFilter
        av_bsf_free(&adtsFilter)
        var packet: UnsafeMutablePointer<AVPacket>? = packet
        av_packet_free(&packet)
        Self.closeBuffer(of: context)
        avformat_free_context(context)
    }

    /// A fragment, when this packet closed one.
    func append(_ packet: DemuxedPacket) throws(SegmentWriter.Failure) -> Data? {
        guard let time = packet.presentationTime else { throw .untimedSample }
        let presentation = rendition.clock.ticks(at: time)
        guard presentation >= lastAssigned else { throw .reorderedTooFar }
        unassigned.insert(presentation, at: unassigned.firstIndex { $0 > presentation } ?? unassigned.endIndex)
        waiting.append((packet, presentation))
        return waiting.count > lookahead ? try writeFirstWaiting() : nil
    }

    /// The rest of the segment. Throws `noSamples` for a segment that held none.
    func finish() throws(SegmentWriter.Failure) -> Data {
        let unfinished = (framesWritten + waiting.count) % framesPerSample
        waiting.removeLast(unfinished)
        // Joined frames are audio, whose decode times are its presentation times in order.
        unassigned.removeLast(unfinished)
        var rest = Data()
        while !waiting.isEmpty {
            if let fragment = try writeFirstWaiting() { rest.append(fragment) }
        }
        if fragmentStart != nil { rest.append(try closeFragment()) }
        guard wroteFragment else { throw .noSamples }
        return rest
    }

    /// The `ftyp` and `moov`, written with the first MP4 sample alone, which takes the smallest
    /// presentation time appended as its decode time. The muxer describes the track by its
    /// first sample: the packets after it only need to be enough to know that time.
    func headerWithFirstSample() throws(SegmentWriter.Failure) -> Data {
        if header == nil {
            guard waiting.count >= framesPerSample else { throw .noSamples }
            var closed = false
            for _ in 0..<framesPerSample { closed = try writeFirstWaiting() != nil }
            if !closed { _ = try closeFragment() }
        }
        guard let header else { throw .noFragment }
        return header
    }

    private func writeFirstWaiting() throws(SegmentWriter.Failure) -> Data? {
        let (sample, presentation) = waiting.removeFirst()
        let decode = unassigned.removeFirst()
        lastAssigned = decode
        fragmentStart = fragmentStart ?? decode

        // A sample lasts until the next decodes, whatever rate the stream declares: the muxer
        // takes a packet that decodes before the one ahead of it ends for a broken stream, and
        // drops its presentation time.
        let duration: Int64
        if let next = unassigned.first {
            duration = next - decode
        } else {
            let step = rendition.clock.grid?.step
                ?? sample.duration.map { $0 * rendition.clock.timescale / 1_000_000_000 } ?? 0
            // Samples of neighboring segments meet within one sample's length. A gap of a
            // sample or more means the rendition stopped, or its unfinished last sample was
            // left out.
            let gap = end.map { rendition.clock.ticks(at: $0) - presentation - step } ?? 0
            duration = gap >= step ? step + gap : step
        }

        try SegmentWriter.check(av_new_packet(packet, Int32(sample.data.count)))
        defer { av_packet_unref(packet) }
        sample.data.copyBytes(to: packet.pointee.data, count: sample.data.count)
        packet.pointee.stream_index = 0
        packet.pointee.pts = av_rescale_q(presentation, timescale, timeBase)
        packet.pointee.dts = av_rescale_q(decode - rendition.decodeLead, timescale, timeBase)
        packet.pointee.duration = av_rescale_q(duration, timescale, timeBase)
        if sample.isKeyframe { packet.pointee.flags |= AV_PKT_FLAG_KEY }
        if let adtsFilter {
            try SegmentWriter.check(av_bsf_send_packet(adtsFilter, packet))
            try SegmentWriter.check(av_bsf_receive_packet(adtsFilter, packet))
        }
        try SegmentWriter.check(av_write_frame(context, packet))

        fragmentBytes += sample.data.count
        fragmentTicks += duration
        framesWritten += 1
        let full = fragmentBytes >= byteLimit || Double(fragmentTicks) >= tickLimit
        return full && framesWritten % framesPerSample == 0 ? try closeFragment() : nil
    }

    private func closeFragment() throws(SegmentWriter.Failure) -> Data {
        // A null packet flushes. With `delay_moov` the first flush writes the `moov` the
        // packets described, and the second writes them as a fragment.
        if !wroteFragment { try SegmentWriter.check(av_write_frame(context, nil)) }
        try SegmentWriter.check(av_write_frame(context, nil))
        var bytes = try takeBuffer()
        if header == nil {
            guard let moof = SegmentWriter.offsetOfBox("moof", in: bytes) else { throw .noFragment }
            header = bytes.prefix(moof)
            bytes = Data(bytes.dropFirst(moof))
        }
        guard let start = fragmentStart else { throw .noFragment }
        try Self.date(&bytes, at: start)
        wroteFragment = true
        fragmentStart = nil
        fragmentBytes = 0
        fragmentTicks = 0
        return bytes
    }

    /// The muxer dates a fragment by its own running decode time, and the first by its first
    /// sample's presentation time less the edit list's lead. Each fragment is dated instead by
    /// the decode time its first sample took plus the lead: the presentation time of that rank.
    /// For a segment's first fragment that is its earliest presentation time. Dated by its
    /// first decoded sample, an open-GOP segment would play late by the pictures its keyframe
    /// decodes before.
    private static func date(_ bytes: inout Data, at time: Int64) throws(SegmentWriter.Failure) {
        let base = bytes.startIndex
        guard let moof = SegmentWriter.offsetOfBox("moof", in: bytes),
              let traf = SegmentWriter.offsetOfBox("traf", in: bytes, inside: moof),
              let tfdt = SegmentWriter.offsetOfBox("tfdt", in: bytes, inside: traf),
              // Version 1: a 64-bit decode time after the header, version and flags.
              bytes[base + tfdt + 8] == 1, time >= 0
        else { throw .noFragment }
        let field = base + tfdt + 12
        bytes.replaceSubrange(field..<field + 8, with: withUnsafeBytes(of: UInt64(time).bigEndian) { Data($0) })
    }

    /// What the muxer wrote since the last call, with a fresh buffer opened behind it so the
    /// segment's bytes are never all held at once.
    private func takeBuffer() throws(SegmentWriter.Failure) -> Data {
        avio_flush(context.pointee.pb)
        var buffer: UnsafeMutablePointer<UInt8>?
        let size = avio_close_dyn_buf(context.pointee.pb, &buffer)
        context.pointee.pb = nil
        defer { av_free(buffer) }
        try SegmentWriter.check(avio_open_dyn_buf(&context.pointee.pb))
        guard let buffer, size > 0 else { throw .noFragment }
        return Data(bytes: buffer, count: Int(size))
    }

    private static func closeBuffer(of context: UnsafeMutablePointer<AVFormatContext>) {
        guard context.pointee.pb != nil else { return }
        var buffer: UnsafeMutablePointer<UInt8>?
        avio_close_dyn_buf(context.pointee.pb, &buffer)
        av_free(buffer)
        context.pointee.pb = nil
    }

    private static func adtsFilter(
        for parameters: CodecParameters
    ) throws(SegmentWriter.Failure) -> UnsafeMutablePointer<AVBSFContext> {
        var allocated: UnsafeMutablePointer<AVBSFContext>?
        guard let named = av_bsf_get_by_name("aac_adtstoasc"), av_bsf_alloc(named, &allocated) >= 0,
              let filter = allocated
        else { throw .outOfMemory }
        do throws(SegmentWriter.Failure) {
            try SegmentWriter.check(avcodec_parameters_copy(filter.pointee.par_in, parameters.pointer))
            try SegmentWriter.check(av_bsf_init(filter))
        } catch {
            av_bsf_free(&allocated)
            throw error
        }
        return filter
    }

    /// The time base the muxer chose for the stream.
    private static func writeHeader(
        of rendition: Rendition, into context: UnsafeMutablePointer<AVFormatContext>
    ) throws(SegmentWriter.Failure) -> AVRational {
        // The muxer writes the Dolby Vision record into the sample entry only past official
        // compliance, and only where the playlist names the layer.
        if rendition.supplementalCodec != nil {
            context.pointee.strict_std_compliance = FF_COMPLIANCE_UNOFFICIAL
        }
        guard let stream = avformat_new_stream(context, nil) else { throw .outOfMemory }
        try SegmentWriter.check(avcodec_parameters_copy(stream.pointee.codecpar, rendition.stream.parameters.pointer))
        // The sample entry the playlist declared: the codec string's first four characters.
        // Left to itself the muxer stores HEVC as `hev1`, which AVPlayer does not play.
        stream.pointee.codecpar.pointee.codec_tag = rendition.codec.utf8.prefix(4).reversed()
            .reduce(0) { $0 << 8 | UInt32($1) }
        if rendition.stream.kind == .audio, let frame = rendition.clock.grid?.step {
            stream.pointee.codecpar.pointee.frame_size = Int32(frame)
        }
        stream.pointee.time_base = AVRational(num: 1, den: Int32(rendition.clock.timescale))

        try SegmentWriter.check(avio_open_dyn_buf(&context.pointee.pb))
        var options: OpaquePointer?
        defer { av_dict_free(&options) }
        av_dict_set(&options, "movflags", SegmentWriter.flags, 0)
        av_dict_set(&options, "video_track_timescale", "\(rendition.clock.timescale)", 0)
        try SegmentWriter.check(avformat_write_header(context, &options))
        return stream.pointee.time_base
    }
}
