import AetherLibavcodec
import AetherLibavformat
import AetherLibavutil
import Dispatch
import Foundation
import ParallaxCore

/// One elementary stream of a container.
struct DemuxedStream: Sendable {
    enum Kind: Sendable, Equatable { case video, audio, subtitle, other }

    let index: Int
    let kind: Kind
    let parameters: CodecParameters
    /// Nanoseconds in one unit of the container's clock for this stream. A stored time is
    /// exact only to this.
    let tick: Int64
    /// Frames per second as the container declares it. Nil for audio, and when it says nothing.
    let frameRate: FrameRate?
    /// As the container spells it: "jpn", "en". Nil when it names none.
    let language: String?
    let title: String?
    /// The container marks the stream as the one to play when the viewer chose none.
    let isDefault: Bool

    struct FrameRate: Sendable, Equatable {
        let numerator: Int64
        let denominator: Int64
    }
}

/// One compressed sample, byte for byte as the container stores it.
struct DemuxedPacket: Sendable, Equatable {
    let stream: Int
    /// Nanoseconds. Nil when the container gives the sample no time.
    let presentationTime: Int64?
    /// Nanoseconds. Nil when the container gives the sample no length.
    let duration: Int64?
    let isKeyframe: Bool
    let data: Data
}

/// A video keyframe the container's index points at: a place a read can start.
struct IndexedKeyframe: Sendable, Equatable {
    /// Nanoseconds.
    let time: Int64
    /// Where in the file a read for this keyframe starts.
    let position: Int64
}

/// A container opened through libavformat, read in spans between indexed keyframes.
///
/// `packets(from:to:)` returns the same packets for the same span whatever was read before it,
/// which is what lets a segment be built from its index alone.
///
/// The actor runs on a queue of its own because libavformat blocks its thread on every read.
actor MediaDemuxer {
    enum OpenFailure: Error, Equatable {
        case outOfMemory
        /// libavformat does not recognize the bytes, or the headers are damaged.
        case unreadableContainer(code: Int32)
        /// A container this demuxer cannot read in spans yet. Only Matroska can be: spans start
        /// with a byte seek, which the other demuxers refuse.
        case unsupportedContainer(name: String)
        case noVideoStream
    }

    /// libavformat stopped a read with a code of its own while the reader reported no error:
    /// damaged data in the middle of the file.
    struct ReadFailure: Error, Equatable {
        let code: Int32
    }

    nonisolated let streams: [DemuxedStream]
    nonisolated let videoStream: Int
    /// Nanoseconds. Nil when the container does not say.
    nonisolated let duration: Int64?
    nonisolated let fileSize: Int64

    private let queue: DispatchSerialQueue
    private let source: DemuxerSource
    private let context: UnsafeMutablePointer<AVFormatContext>
    private let packet: UnsafeMutablePointer<AVPacket>
    private var loadedKeyframes: [IndexedKeyframe]?

    nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    static func open(_ reader: any RandomAccessReading) async throws -> MediaDemuxer {
        let size = try await reader.fileSize
        let queue = DispatchSerialQueue(label: "parallax.media-demuxer", qos: .userInitiated)
        let opened = try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: Result { try Opened(reader: reader, size: size) })
            }
        }
        return MediaDemuxer(opened, queue: queue)
    }

    private init(_ opened: sending Opened, queue: DispatchSerialQueue) {
        self.queue = queue
        source = opened.source
        context = opened.context
        packet = opened.packet
        streams = opened.streams
        videoStream = opened.videoStream
        duration = opened.duration
        fileSize = opened.fileSize
    }

    isolated deinit {
        var packet: UnsafeMutablePointer<AVPacket>? = packet
        av_packet_free(&packet)
        let io = context.pointee.pb
        var context: UnsafeMutablePointer<AVFormatContext>? = context
        avformat_close_input(&context)
        DemuxerSource.free(io)
    }

    /// The video stream's index, in file order. Matroska loads its Cues on the first seek, so
    /// the first call reads them.
    func keyframes() throws -> [IndexedKeyframe] {
        if let loadedKeyframes { return loadedKeyframes }
        try check(av_seek_frame(context, Int32(videoStream), 0, AVSEEK_FLAG_BACKWARD))
        // The seek reports success when the read of the Cues failed, and the index is then
        // short or empty.
        if let failure = source.takeFailure() { throw failure }
        let stream = context.pointee.streams[videoStream]
        let entries = (0..<avformat_index_get_entries_count(stream)).compactMap { index in
            avformat_index_get_entry(stream, index).map {
                IndexedKeyframe(
                    time: nanoseconds($0.pointee.timestamp, of: videoStream), position: $0.pointee.pos)
            }
        }
        loadedKeyframes = entries
        return entries
    }

    /// The packets of the span that starts at keyframe `lower` and ends before keyframe `upper`,
    /// in file order. `upper` equal to the keyframe count reads to the end of the file.
    ///
    /// Video belongs to the span by position: every video packet from the lower keyframe up to
    /// the upper one, so pictures that display before their keyframe stay with it. Audio belongs
    /// by time: every packet timed in `[lower, upper)`. The first span also takes whatever is
    /// timed before its keyframe. Neighboring spans therefore share no packet and drop none.
    ///
    /// With `takingLaterAudio`, audio has no upper time: the span also takes the audio timed
    /// after it that the read comes by. That is for the span an audio track ends in.
    func packets(from lower: Int, to upper: Int, takingLaterAudio: Bool = false) throws -> [DemuxedPacket] {
        let keyframes = try keyframes()
        precondition(keyframes.indices.contains(lower) && lower < upper && upper <= keyframes.count)
        let lowerTime = lower == 0 ? Int64.min : keyframes[lower].time
        let upperTime = upper == keyframes.count ? Int64.max : keyframes[upper].time
        let audioUpperTime = takingLaterAudio ? Int64.max : upperTime

        // Real muxers store audio up to a cluster ahead of the keyframe it plays with, so the
        // read starts at the nearest entry that sits earlier in the file. It starts there by
        // position because a seek by time makes libavformat drop what precedes the keyframe it
        // lands on. Reading on from a byte seek relies on FFmpegBuild's matroska-byte-seek-done
        // patch.
        let start = keyframes[..<lower].last { $0.position < keyframes[lower].position } ?? keyframes[lower]
        try check(av_seek_frame(context, -1, start.position, AVSEEK_FLAG_BYTE))

        var collected: [DemuxedPacket] = []
        var videoStarted = false
        var videoEnded = false
        var pendingAudio = Set(streams.filter { $0.kind == .audio }.map(\.index))
        var audioBelonged: [Int: Bool] = [:]
        var bytesPastVideo = 0

        while !(videoEnded && pendingAudio.isEmpty) {
            let status = av_read_frame(context, packet)
            if status == DemuxerSource.Code.endOfFile, !source.hasFailed { break }
            try check(status)
            defer { av_packet_unref(packet) }

            let stream = Int(packet.pointee.stream_index)
            let time = packet.pointee.pts == Self.noTime ? nil : nanoseconds(packet.pointee.pts, of: stream)
            let isKeyframe = packet.pointee.flags & AV_PKT_FLAG_KEY != 0

            let belongs: Bool
            if stream == videoStream {
                if isKeyframe, let time {
                    if time >= upperTime { videoEnded = true } else if time >= lowerTime { videoStarted = true }
                }
                belongs = videoStarted && !videoEnded
            } else if pendingAudio.contains(stream) {
                // A frame with no time of its own follows the one before it in its lace.
                if let time {
                    if time >= audioUpperTime { pendingAudio.remove(stream) }
                    audioBelonged[stream] = time >= lowerTime && time < audioUpperTime
                }
                belongs = audioBelonged[stream] ?? false
            } else {
                belongs = false
            }

            if belongs, let bytes = packet.pointee.data {
                collected.append(DemuxedPacket(
                    stream: stream, presentationTime: time,
                    duration: packet.pointee.duration > 0 ? nanoseconds(packet.pointee.duration, of: stream) : nil,
                    isKeyframe: isKeyframe,
                    data: Data(bytes: bytes, count: Int(packet.pointee.size))))
            }
            if videoEnded {
                // An audio track that ends early never reaches the boundary. Without a limit
                // the read would run to the end of the file looking for it.
                bytesPastVideo += Int(packet.pointee.size)
                if bytesPastVideo > Self.audioSearchLimit { break }
            }
        }
        return collected
    }

    /// Which of `streams` have a packet timed at or after keyframe `index` and stored at or
    /// after it. A stream that runs on shows one within a moment of the keyframe, so the read
    /// is short when all of them do. It gives up on the rest once the video is `interleaveLimit`
    /// past the keyframe.
    func streams(_ streams: Set<Int>, continuingPastKeyframe index: Int) throws -> Set<Int> {
        let keyframe = try keyframes()[index]
        try check(av_seek_frame(context, -1, keyframe.position, AVSEEK_FLAG_BYTE))
        var continuing: Set<Int> = []
        while continuing != streams {
            let status = av_read_frame(context, packet)
            if status == DemuxerSource.Code.endOfFile, !source.hasFailed { break }
            try check(status)
            defer { av_packet_unref(packet) }
            guard packet.pointee.pts != Self.noTime else { continue }
            let from = Int(packet.pointee.stream_index)
            let time = nanoseconds(packet.pointee.pts, of: from)
            if streams.contains(from), time >= keyframe.time { continuing.insert(from) }
            if from == videoStream, time >= keyframe.time + Self.interleaveLimit { break }
        }
        return continuing
    }

    private static let audioSearchLimit = 4 << 20
    /// Nanoseconds. Muxers store a stream's packets within a cluster of the video they play
    /// with, and a cluster holds five seconds at most.
    private static let interleaveLimit: Int64 = 5_000_000_000
    private static let nanoseconds = AVRational(num: 1, den: 1_000_000_000)
    /// `AV_NOPTS_VALUE`, which does not import into Swift.
    private static let noTime = Int64.min

    private func nanoseconds(_ value: Int64, of stream: Int) -> Int64 {
        av_rescale_q(value, timeBase(of: stream), Self.nanoseconds)
    }

    private func timeBase(of stream: Int) -> AVRational {
        context.pointee.streams[stream]?.pointee.time_base ?? Self.nanoseconds
    }

    private func check(_ status: Int32) throws {
        guard status < 0 else { return }
        throw source.takeFailure() ?? ReadFailure(code: status)
    }
}

/// What opening a container produces, built on the demuxer's queue before the actor exists.
private struct Opened {
    let source: DemuxerSource
    let context: UnsafeMutablePointer<AVFormatContext>
    let packet: UnsafeMutablePointer<AVPacket>
    let streams: [DemuxedStream]
    let videoStream: Int
    let duration: Int64?
    let fileSize: Int64

    init(reader: any RandomAccessReading, size: UInt64) throws {
        let source = DemuxerSource(reader: reader, size: size)
        guard let io = source.makeContext() else { throw MediaDemuxer.OpenFailure.outOfMemory }
        guard let packet = av_packet_alloc() else {
            DemuxerSource.free(io)
            throw MediaDemuxer.OpenFailure.outOfMemory
        }
        guard let allocated = avformat_alloc_context() else {
            var packet: UnsafeMutablePointer<AVPacket>? = packet
            av_packet_free(&packet)
            DemuxerSource.free(io)
            throw MediaDemuxer.OpenFailure.outOfMemory
        }
        allocated.pointee.pb = io

        // On failure avformat_open_input frees the context it was given, but not our I/O.
        var context: UnsafeMutablePointer<AVFormatContext>? = allocated
        var status = avformat_open_input(&context, nil, nil, nil)
        if status >= 0 {
            // libavformat reads up to 5 MB of media to describe the streams, and most of that
            // is spent waiting for a subtitle stream to show a packet. One megabyte gave the
            // same codec, profile, reorder depth and frame rate on 74 real files.
            context?.pointee.probesize = 1_000_000
            status = avformat_find_stream_info(context, nil)
        }
        let video = status >= 0 ? av_find_best_stream(context, AVMEDIA_TYPE_VIDEO, -1, -1, nil, 0) : -1

        let format = context?.pointee.iformat.map { String(cString: $0.pointee.name) } ?? ""
        // libavformat takes a failed read while it describes the streams for the end of the
        // file and reports success.
        let failure = source.takeFailure()
        guard let context, failure == nil, status >= 0, video >= 0, format.contains("matroska") else {
            var packet: UnsafeMutablePointer<AVPacket>? = packet
            av_packet_free(&packet)
            avformat_close_input(&context)
            DemuxerSource.free(io)
            if let failure { throw failure }
            if status < 0 { throw MediaDemuxer.OpenFailure.unreadableContainer(code: status) }
            if video < 0 { throw MediaDemuxer.OpenFailure.noVideoStream }
            throw MediaDemuxer.OpenFailure.unsupportedContainer(name: format)
        }

        self.source = source
        self.context = context
        self.packet = packet
        videoStream = Int(video)
        fileSize = Int64(clamping: size)
        // `AV_TIME_BASE` units, which are microseconds.
        duration = context.pointee.duration > 0 ? context.pointee.duration * 1000 : nil
        let nanoseconds = AVRational(num: 1, den: 1_000_000_000)
        let described = (0..<Int(context.pointee.nb_streams)).map { index -> DemuxedStream? in
            guard let stream = context.pointee.streams[index]?.pointee,
                  let parameters = CodecParameters(copying: stream.codecpar)
            else { return nil }
            let kind: DemuxedStream.Kind = switch stream.codecpar.pointee.codec_type {
            case AVMEDIA_TYPE_VIDEO: .video
            case AVMEDIA_TYPE_AUDIO: .audio
            case AVMEDIA_TYPE_SUBTITLE: .subtitle
            default: .other
            }
            let rate = stream.avg_frame_rate
            func tag(_ key: String) -> String? {
                av_dict_get(stream.metadata, key, nil, 0).map { String(cString: $0.pointee.value) }
                    .flatMap { $0.isEmpty ? nil : $0 }
            }
            return DemuxedStream(
                index: index, kind: kind, parameters: parameters,
                tick: av_rescale_q(1, stream.time_base, nanoseconds),
                frameRate: kind == .video && rate.num > 0 && rate.den > 0
                    ? .init(numerator: Int64(rate.num), denominator: Int64(rate.den)) : nil,
                language: tag("language").flatMap { $0 == "und" ? nil : $0 }, title: tag("title"),
                isDefault: stream.disposition & AV_DISPOSITION_DEFAULT != 0)
        }
        streams = described.compactMap(\.self)
        guard streams.count == described.count else {
            var packet: UnsafeMutablePointer<AVPacket>? = packet
            av_packet_free(&packet)
            var context: UnsafeMutablePointer<AVFormatContext>? = context
            avformat_close_input(&context)
            DemuxerSource.free(io)
            throw MediaDemuxer.OpenFailure.outOfMemory
        }
    }
}
