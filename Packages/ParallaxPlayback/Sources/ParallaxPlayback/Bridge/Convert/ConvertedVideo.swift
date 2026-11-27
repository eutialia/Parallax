import AetherLibavutil
import Foundation

/// A video stream delivered as HEVC: decoded, and encoded again segment by segment. Built from
/// the first picture the decoder gave and what the encoder made of it, never from what the
/// container claims.
struct ConvertedVideo: Sendable {
    /// Pictures a second the encoder is told to expect of a stream whose container names no
    /// rate.
    static let assumedFrameRate = 30.0

    let stream: DemuxedStream
    /// What every request's encoder is asked for.
    let format: HEVCFormat
    /// The encoder's `hvcC` record: its parameter sets, which the init segment carries for
    /// every segment.
    let record: Data
    /// The HEVC stream as the MP4 muxer describes it.
    let encoded: CodecParameters
    /// The RFC 6381 string a playlist's `CODECS` carries: "hvc1.2.4.L120.B0".
    let codec: String
    /// The stream's first picture as HEVC, which the init segment is described by.
    let firstPicture: [MediaPacket]
    /// Pictures per second as the playlist declares it: the container's rate, and twice that
    /// for a stream of fields, which gives a picture for each. Nil when the container says
    /// nothing.
    let frameRate: DemuxedStream.FrameRate?

    /// `packets` are the stream's own, of those the file opens with, and `start` is the
    /// earliest time among them. Throws `videoCodec` for a stream the decoder gives no picture
    /// of, and `videoEncoder` when `openEncoder` gives no encoder or the encoder no picture.
    init(
        _ stream: DemuxedStream, openingWith packets: [MediaPacket], startingAt start: Int64,
        openEncoder: (HEVCFormat) throws -> HEVCEncoder
    ) throws(BridgeRefusal) {
        let name = stream.parameters.displayName
        guard let decoder = try? VideoDecoder(stream.parameters, timedByDecodeOrder: stream.packetTimes == .decodeOnly) else {
            throw .videoCodec(name: name)
        }
        // The rate of a stream of fields is read off its first two pictures.
        let isInterlaced = stream.parameters.isInterlaced
        var times: [Int64] = []
        var first: UnsafeMutablePointer<AVFrame>?
        defer { av_frame_free(&first) }
        func keep(_ frame: UnsafePointer<AVFrame>) {
            if first == nil { first = av_frame_clone(frame) }
            if frame.pointee.pts != VideoDecoder.noTime { times.append(frame.pointee.pts) }
        }
        let made: (format: HEVCFormat, picture: EncodedPicture, record: Data)?
        let frameRate: DemuxedStream.FrameRate?
        do {
            func hasEnough() -> Bool { isInterlaced ? times.count > 1 : first != nil }
            for packet in packets where !hasEnough() { try decoder.decode(packet, into: keep) }
            if !hasEnough() { try decoder.finish(into: keep) }
            guard let first else { throw BridgeRefusal.videoCodec(name: name) }
            frameRate = isInterlaced ? Self.fieldRate(of: stream, whosePicturesStartAt: times) : stream.frameRate
            let format = HEVCFormat(of: first, in: stream, at: frameRate)
            let encoder = try openEncoder(format)
            try encoder.encode(first, at: 0)
            try encoder.finish()
            let picture = try encoder.takeEncoded().first
            made = picture.flatMap { picture in encoder.records.first.map { (format, picture, $0) } }
        } catch let refusal as BridgeRefusal {
            throw refusal
        } catch HEVCEncoder.Failure.scaler {
            // A picture in a form swscale does not repack is the stream's, not the device's.
            throw .videoCodec(name: name)
        } catch is VideoDecoder.Failure {
            throw .videoCodec(name: name)
        } catch {
            throw .videoEncoder(name: name)
        }
        guard let made,
              let encoded = CodecParameters(hevc: made.record, of: made.format, replacing: stream.parameters),
              let codec = encoded.playlistCodec
        else { throw .videoEncoder(name: name) }

        self.stream = stream
        format = made.format
        record = made.record
        self.encoded = encoded
        self.codec = codec
        self.frameRate = frameRate
        firstPicture = [
            MediaPacket(
                stream: stream.index, presentationTime: start, decodeTime: nil, duration: nil, isKeyframe: true, data: made.picture.data,
                primingSamples: 0)
        ]
    }

    /// Pictures a second of a stream of fields: twice the container's rate, unless the first
    /// two pictures are as far apart as that rate says already. Some streams of fields declare
    /// the rate of their fields and most that of their frames.
    private static func fieldRate(
        of stream: DemuxedStream, whosePicturesStartAt times: [Int64]
    ) -> DemuxedStream.FrameRate? {
        guard let declared = stream.frameRate else { return nil }
        let period = 1_000_000_000 * Double(declared.denominator) / Double(declared.numerator)
        let declaresFields = times.count > 1 && abs(Double(times[1] - times[0]) - period) < period / 8
        return declaresFields ? declared : .init(numerator: declared.numerator * 2, denominator: declared.denominator)
    }
}

extension HEVCFormat {
    /// What a stream whose decoder gave `frame` is encoded as. The picture says its size,
    /// depth and range. Its color is the picture's, and the container's where the picture
    /// names none.
    init(of frame: UnsafePointer<AVFrame>, in stream: DemuxedStream, at frameRate: DemuxedStream.FrameRate?) {
        let source = stream.parameters.pointer.pointee
        let depth = av_pix_fmt_desc_get(AVPixelFormat(rawValue: frame.pointee.format))?.pointee.comp.0.depth ?? 8
        let range = frame.pointee.color_range == AVCOL_RANGE_UNSPECIFIED ? source.color_range : frame.pointee.color_range
        let frameRate = frameRate.map { Double($0.numerator) / Double($0.denominator) }
            ?? ConvertedVideo.assumedFrameRate
        let matrix = frame.pointee.colorspace == AVCOL_SPC_UNSPECIFIED ? source.color_space : frame.pointee.colorspace
        self.init(
            width: Int(frame.pointee.width), height: Int(frame.pointee.height), isTenBit: depth > 8,
            isFullRange: range == AVCOL_RANGE_JPEG,
            frameRate: frameRate,
            primaries: Int32(
                (frame.pointee.color_primaries == AVCOL_PRI_UNSPECIFIED
                    ? source.color_primaries : frame.pointee.color_primaries).rawValue),
            transfer: Int32(
                (frame.pointee.color_trc == AVCOL_TRC_UNSPECIFIED ? source.color_trc : frame.pointee.color_trc).rawValue),
            // BT.470BG and SMPTE 170M are one matrix under two code points (H.273), and Core
            // Video names only the second. VP8 pictures say the first.
            matrix: Int32((matrix == AVCOL_SPC_BT470BG ? AVCOL_SPC_SMPTE170M : matrix).rawValue))
    }
}

/// One segment of a converted video rendition in the making: the stream's packets in, HEVC
/// pictures out.
///
/// The segment holds the pictures whose ticks are in `ticks`, so neighboring segments share no
/// picture and drop none. The read starts at the segment's keyframe and runs past the next
/// one: a decoder gives pictures in the order they are shown, some of them only when handed
/// later packets, and pictures shown before a keyframe may be stored after it. Each request
/// has an encoder of its own, whose first picture is a keyframe, so a segment plays without the
/// one before it.
///
/// Lives on one thread: the demuxer's queue that reads the segment.
final class VideoConversion: PacketSink {
    private let record: Data
    private let clock: MediaClock
    private let ticks: Range<Int64>
    private let timer: ConversionTimer
    private let cancelled: () -> Bool
    private let take: (Data, _ isKeyframe: Bool, _ tick: Int64, _ length: Int64?) throws -> Void
    private let decoder: VideoDecoder
    private let encoder: HEVCEncoder

    /// The decoder gave a picture of a later segment, so it has given all of this one's.
    private var decodedPastEnd = false
    /// The tick of the last picture handed to the encoder.
    private var lastEncoded: Int64?
    private var firstHanded: Int64?
    private var lastHanded: Int64?

    /// `ticks` are the segment's on the rendition's clock, to `.max` for the file's last.
    /// `take` is handed each picture with its tick and, after the first, the ticks since the
    /// one before.
    init(
        _ video: ConvertedVideo, of rendition: Rendition, ticks: Range<Int64>,
        stopwatch: @escaping () -> () -> Duration, cancelled: @escaping () -> Bool,
        into take: @escaping (Data, _ isKeyframe: Bool, _ tick: Int64, _ length: Int64?) throws -> Void
    ) throws {
        record = video.record
        clock = rendition.packetClock
        self.ticks = ticks
        timer = ConversionTimer(stopwatch)
        self.cancelled = cancelled
        self.take = take
        decoder = try VideoDecoder(video.stream.parameters, timedByDecodeOrder: video.stream.packetTimes == .decodeOnly)
        encoder = try HEVCEncoder(video.format, timescale: rendition.clock.timescale)
    }

    var isCancelled: Bool { cancelled() }

    var isSatisfied: Bool { decodedPastEnd }

    /// Seconds of the segment for each second its decoding and encoding took. Nil for a
    /// segment of fewer than two pictures, and on a clock that does not move.
    var speed: Double? {
        guard let firstHanded, let lastHanded else { return nil }
        return timer.speed(converting: Double(lastHanded - firstHanded) / Double(clock.timescale))
    }

    func accept(_ packet: MediaPacket) throws {
        try timer.work {
            try decoder.decode(packet, into: encode)
            try handEncoded()
        }
    }

    /// The rest of the segment, once the read has returned.
    func finish() throws {
        try timer.work {
            // The read returned short of the segment's end: the stream has no more packets.
            if !decodedPastEnd { try decoder.finish(into: encode) }
            try encoder.finish()
            try handEncoded()
        }
    }

    private func encode(_ frame: UnsafePointer<AVFrame>) throws {
        if cancelled() { throw CancellationError() }
        let time = frame.pointee.pts
        guard !decodedPastEnd, time != VideoDecoder.noTime else { return }
        let tick = clock.ticks(at: time)
        guard tick < ticks.upperBound else {
            decodedPastEnd = true
            return
        }
        // A damaged stream's decoder can give a picture timed before one it already gave, and
        // the muxer fails a segment whose times go back.
        guard tick >= ticks.lowerBound, lastEncoded.map({ tick > $0 }) ?? true else { return }
        try encoder.encode(frame, at: tick)
        lastEncoded = tick
    }

    private func handEncoded() throws {
        let pictures = try encoder.takeEncoded()
        if let other = encoder.records.first(where: { $0 != record }) {
            throw SegmentWriter.Failure.parameterSetsChanged(
                from: record.base64EncodedString(), to: other.base64EncodedString())
        }
        for picture in pictures {
            let length = lastHanded.map { picture.tick - $0 }
            try timer.hand { try take(picture.data, picture.isKeyframe, picture.tick, length) }
            firstHanded = firstHanded ?? picture.tick
            lastHanded = picture.tick
        }
    }
}
