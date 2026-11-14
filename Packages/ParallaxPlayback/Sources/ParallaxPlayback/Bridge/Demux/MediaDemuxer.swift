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

/// Takes one read's packets, on the demuxer's queue, which it may block.
protocol PacketSink: AnyObject {
    /// Checked between packets: a read whose sink is cancelled stops with `CancellationError`.
    var isCancelled: Bool { get }
    func accept(_ packet: DemuxedPacket) throws
}

/// A container opened through libavformat, read in spans between indexed keyframes.
///
/// A read returns the same packets for the same span whatever was read before it, which is
/// what lets a segment be built from its index alone.
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

    /// What this demuxer's reads have fetched from the reader, rather than found kept.
    var bytesFetched: Int { source.bytesFetched }

    /// A demuxer with blocks of its own.
    static func open(_ reader: any RandomAccessReading) async throws -> MediaDemuxer {
        try await open(SessionBlockCache(reader: reader, size: try await reader.fileSize))
    }

    /// A demuxer over blocks other demuxers of the file share. With `keyframes`, the index one
    /// of them read, it reads no index of its own.
    static func open(_ cache: SessionBlockCache, keyframes: [IndexedKeyframe]? = nil) async throws -> MediaDemuxer {
        let queue = DispatchSerialQueue(label: "parallax.media-demuxer", qos: .userInitiated)
        let opened = try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: Result { try Opened(cache: cache) })
            }
        }
        return MediaDemuxer(opened, keyframes: keyframes, queue: queue)
    }

    private init(_ opened: sending Opened, keyframes: [IndexedKeyframe]?, queue: DispatchSerialQueue) {
        self.queue = queue
        source = opened.source
        context = opened.context
        packet = opened.packet
        streams = opened.streams
        videoStream = opened.videoStream
        duration = opened.duration
        fileSize = opened.fileSize
        loadedKeyframes = keyframes
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

    /// The packets of `stream` in the span that starts at keyframe `lower` and ends before
    /// keyframe `upper`, in file order, handed to `sink` as they are read. `upper` equal to the
    /// keyframe count reads to the end of the file.
    ///
    /// Video belongs to the span by position: every packet from the lower keyframe up to the
    /// upper one, so pictures that display before their keyframe stay with it. Audio belongs by
    /// time: every packet timed in `[lower, upper)`. The first span also takes whatever is timed
    /// before its keyframe. Neighboring spans therefore share no packet and drop none.
    ///
    /// With `takingLaterAudio`, audio has no upper time: the span also takes the audio timed
    /// after it that the read comes by. That is for the span an audio track ends in.
    ///
    /// An audio frame is timed by where `clock` starts the MP4 sample it goes into, so frames
    /// the muxer joins stay in one span.
    func read<Sink: PacketSink>(
        _ stream: Int, from lower: Int, to upper: Int, takingLaterAudio: Bool = false, clock: MediaClock? = nil,
        into sink: Sink
    ) throws {
        let keyframes = try keyframes()
        precondition(keyframes.indices.contains(lower) && lower < upper && upper <= keyframes.count)
        let lowerTime = lower == 0 ? Int64.min : keyframes[lower].time
        let upperTime = upper == keyframes.count ? Int64.max : keyframes[upper].time
        if stream == videoStream {
            // A video span needs nothing stored before its keyframe, and an index entry is
            // where a cluster starts.
            try seek(to: keyframes[lower].position)
            try readVideo(from: lowerTime, to: upperTime, into: sink)
            return
        }
        // Muxers store audio up to a cluster ahead of the keyframe it plays with, so the read
        // starts a cluster or more earlier. The last place it can start is the previous index
        // entry, which may be a long span back.
        let floor = keyframes[..<lower].last { $0.position < keyframes[lower].position }?.position
            ?? keyframes[lower].position
        var back = lower == 0 ? 0 : Self.audioLookback(before: keyframes[lower], after: keyframes[lower - 1])
        while true {
            let from = keyframes[lower].position - back
            let start = from <= floor ? nil
                : try clusterStart(from: from, before: keyframes[lower], after: keyframes[lower - 1].time)
            // A cluster may run 32 s: with none this close, one further back is still nearer
            // than the floor.
            if start == nil, from > floor {
                back *= 2
                continue
            }
            try seek(to: start ?? floor)
            let audioUpperTime = takingLaterAudio ? Int64.max : upperTime
            let tookItAll = try readAudio(
                stream, from: lowerTime, to: audioUpperTime, videoEnd: upperTime, clock: clock,
                startedEarlyEnough: start == nil, into: sink)
            if tookItAll { return }
            back *= 2
        }
    }

    /// `read`'s packets, collected.
    func packets(
        _ stream: Int, from lower: Int, to upper: Int, takingLaterAudio: Bool = false, clock: MediaClock? = nil
    ) throws -> [DemuxedPacket] {
        let collected = CollectingSink()
        try read(stream, from: lower, to: upper, takingLaterAudio: takingLaterAudio, clock: clock, into: collected)
        return collected.packets
    }

    /// Every packet of every audio and video stream of span `lower..<upper`, the video first.
    /// For tests and the library sweep, which compare a span with its source.
    func packets(from lower: Int, to upper: Int, takingLaterAudio: Bool = false) throws -> [DemuxedPacket] {
        try ([videoStream] + streams.filter { $0.kind == .audio }.map(\.index)).flatMap {
            try packets($0, from: lower, to: upper, takingLaterAudio: takingLaterAudio)
        }
    }

    /// The first span's video and audio packets, in file order, up to the first of: `videoPackets`
    /// video packets and `audioPackets` of each stream in `audio`; `byteLimit` bytes from the
    /// first keyframe; keyframe `upper`. What a plan needs to describe the streams and place
    /// them in time, without reading a first span that may be hundreds of megabytes.
    func opening(
        before upper: Int, videoPackets: Int, audioPackets: Int, of audio: Set<Int>, byteLimit: Int
    ) throws -> [DemuxedPacket] {
        let keyframes = try keyframes()
        let upperTime = upper == keyframes.count ? Int64.max : keyframes[upper].time
        try seek(to: keyframes[0].position)
        var collected: [DemuxedPacket] = []
        var counts: [Int: Int] = [:]
        var bytes = 0
        while let packet = try nextPacket() {
            defer { av_packet_unref(packet) }
            let stream = Int(packet.pointee.stream_index)
            let isKeyframe = packet.pointee.flags & AV_PKT_FLAG_KEY != 0
            if stream == videoStream, isKeyframe, let time = time(of: packet), time >= upperTime { break }
            let started = counts[videoStream] != nil || stream == videoStream && isKeyframe
            guard stream == videoStream ? started : streams[stream].kind == .audio,
                  let demuxed = demuxed(packet)
            else { continue }
            collected.append(demuxed)
            counts[stream, default: 0] += 1
            if started { bytes += demuxed.data.count }
            let enough = counts[videoStream, default: 0] >= videoPackets
                && audio.allSatisfy { counts[$0, default: 0] >= audioPackets }
            if enough || bytes > byteLimit { break }
        }
        return collected
    }

    private func readVideo(from lowerTime: Int64, to upperTime: Int64, into sink: some PacketSink) throws {
        var started = false
        while let packet = try nextPacket() {
            defer { av_packet_unref(packet) }
            if sink.isCancelled { throw CancellationError() }
            guard Int(packet.pointee.stream_index) == videoStream else { continue }
            if packet.pointee.flags & AV_PKT_FLAG_KEY != 0, let time = time(of: packet) {
                if time >= upperTime { return }
                if time >= lowerTime { started = true }
            }
            if started, let demuxed = demuxed(packet) { try sink.accept(demuxed) }
        }
    }

    /// False, having handed nothing to `sink`, when the read started too late: the stream's
    /// first packet is timed at or after the span's start, so what is timed before it may be
    /// stored earlier.
    private func readAudio(
        _ stream: Int, from lowerTime: Int64, to upperTime: Int64, videoEnd: Int64, clock: MediaClock?,
        startedEarlyEnough: Bool, into sink: some PacketSink
    ) throws -> Bool {
        var belongs = false
        var seen = false
        var videoEnded = false
        var bytesPastVideo = 0
        while let packet = try nextPacket() {
            defer { av_packet_unref(packet) }
            if sink.isCancelled { throw CancellationError() }
            let from = Int(packet.pointee.stream_index)
            if from == videoStream, packet.pointee.flags & AV_PKT_FLAG_KEY != 0,
               let time = time(of: packet), time >= videoEnd {
                videoEnded = true
            }
            if from == stream {
                // A frame with no time of its own follows the one before it in its lace.
                if let time = time(of: packet).map({ clock?.sampleStart(at: $0) ?? $0 }) {
                    if !seen, !startedEarlyEnough, time >= lowerTime { return false }
                    seen = true
                    if time >= upperTime { return true }
                    belongs = time >= lowerTime
                }
                if belongs, let demuxed = demuxed(packet) { try sink.accept(demuxed) }
            }
            if videoEnded {
                // An audio track that ends early never reaches the boundary. Without a limit
                // the read would run to the end of the file looking for it.
                bytesPastVideo += Int(packet.pointee.size)
                if bytesPastVideo > Self.audioSearchLimit { return true }
            }
        }
        return true
    }

    /// How far before `keyframe` an audio read first looks for a cluster: eight seconds of the
    /// index span before it, at that span's average rate. Audio is stored up to five seconds
    /// ahead (`interleaveLimit`). Never more than the span itself: two entries with one time
    /// would make the rate unbounded.
    static func audioLookback(before keyframe: IndexedKeyframe, after previous: IndexedKeyframe) -> Int64 {
        let bytes = Double(keyframe.position - previous.position)
        let seconds = Double(max(keyframe.time - previous.time, 1)) / 1e9
        return max(Int64(min(bytes / seconds * 8, bytes)), 1)
    }

    /// The first cluster at or after `offset` and before `keyframe`'s whose time lies between
    /// `previousTime` and the keyframe's. Nil when there is none. A byte seek resyncs on any
    /// four bytes that match a top-level ID, and media payload holds such bytes, so a read never
    /// starts at an offset this has not checked.
    func clusterStart(from offset: Int64, before keyframe: IndexedKeyframe, after previousTime: Int64) throws -> Int64? {
        let clusterID: [UInt8] = [0x1F, 0x43, 0xB6, 0x75]
        // Windows overlap by more than a cluster's ID, size, CRC-32 and Timestamp take, so a
        // cluster cut off at one window's end is read whole in the next.
        let overlap = 32
        var at = offset
        while at < keyframe.position {
            let window = try bytes(at: at, length: Int(min(Int64(1 << 16), keyframe.position - at + Int64(overlap))))
            guard window.count > overlap else { return nil }
            var index = window.startIndex
            while let found = window[index...].firstRange(of: clusterID) {
                let position = at + Int64(found.lowerBound - window.startIndex)
                if position >= keyframe.position { return nil }
                if let time = clusterTime(in: window[found.upperBound...]).map({ nanoseconds($0, of: videoStream) }),
                   time >= previousTime, time <= keyframe.time {
                    return position
                }
                index = found.lowerBound + 1
            }
            at += Int64(window.count - overlap)
        }
        return nil
    }

    /// The Timestamp a cluster starts with, read from the bytes after its ID: a size, then the
    /// Timestamp element (`E7`), which mkvmerge writes first and ffmpeg writes after a CRC-32
    /// (`BF`). In the stream's ticks.
    private func clusterTime(in bytes: Data.SubSequence) -> Int64? {
        // An EBML size is as many bytes long as its first byte has leading zeros, plus one.
        guard let first = bytes.first, first != 0, case let sizeLength = first.leadingZeroBitCount + 1,
              bytes.count > sizeLength + 8 else { return nil }
        let child = bytes.index(bytes.startIndex, offsetBy: sizeLength)
        let crc: [UInt8] = [0xBF, 0x84]
        let element = bytes[child...].starts(with: crc) ? bytes.index(child, offsetBy: 6) : child
        guard bytes[element] == 0xE7 else { return nil }
        let size = bytes[bytes.index(after: element)]
        guard size & 0x80 != 0 else { return nil }
        let length = Int(size & 0x7F)
        let value = bytes.index(element, offsetBy: 2)
        guard (1...8).contains(length), bytes.distance(from: value, to: bytes.endIndex) >= length else { return nil }
        return bytes[value..<bytes.index(value, offsetBy: length)].reduce(0) { $0 << 8 | Int64($1) }
    }

    /// Which of the audio streams `clocks` names have a whole MP4 sample that starts at or after
    /// keyframe `index` and is stored at or after it: what `read` gives the span that starts
    /// there. A stream that runs on shows one within a moment of the keyframe, so the read is
    /// short when all of them do. It gives up on the rest once the video is `interleaveLimit`
    /// past the keyframe.
    func streams(_ clocks: [Int: MediaClock], continuingPastKeyframe index: Int) throws -> Set<Int> {
        let keyframe = try keyframes()[index]
        try seek(to: keyframe.position)
        var frames: [Int: Int64] = [:]
        var continuing: Set<Int> = []
        while continuing.count < clocks.count, let packet = try nextPacket() {
            defer { av_packet_unref(packet) }
            guard let time = time(of: packet) else { continue }
            let from = Int(packet.pointee.stream_index)
            if let clock = clocks[from], clock.sampleStart(at: time) >= keyframe.time {
                frames[from, default: 0] += 1
                if frames[from, default: 0] >= clock.grid?.framesPerSample ?? 1 { continuing.insert(from) }
            }
            if from == videoStream, time >= keyframe.time + Self.interleaveLimit { break }
        }
        return continuing
    }

    /// The next packet, or nil at the end of the file. The caller unrefs it.
    private func nextPacket() throws -> UnsafeMutablePointer<AVPacket>? {
        let status = av_read_frame(context, packet)
        if status == DemuxerSource.Code.endOfFile, !source.hasFailed { return nil }
        try check(status)
        return packet
    }

    private func time(of packet: UnsafeMutablePointer<AVPacket>) -> Int64? {
        packet.pointee.pts == Self.noTime ? nil : nanoseconds(packet.pointee.pts, of: Int(packet.pointee.stream_index))
    }

    /// Nil for a packet that carries no bytes.
    private func demuxed(_ packet: UnsafeMutablePointer<AVPacket>) -> DemuxedPacket? {
        let stream = Int(packet.pointee.stream_index)
        return packet.pointee.data.map { bytes in
            DemuxedPacket(
                stream: stream, presentationTime: time(of: packet),
                duration: packet.pointee.duration > 0 ? nanoseconds(packet.pointee.duration, of: stream) : nil,
                isKeyframe: packet.pointee.flags & AV_PKT_FLAG_KEY != 0,
                data: Data(bytes: bytes, count: Int(packet.pointee.size)))
        }
    }

    /// Reading on from a byte seek relies on FFmpegBuild's matroska-byte-seek-done patch. A
    /// seek by time would make libavformat drop what precedes the keyframe it lands on.
    private func seek(to position: Int64) throws {
        try check(av_seek_frame(context, -1, position, AVSEEK_FLAG_BYTE))
    }

    private func bytes(at offset: Int64, length: Int) throws -> Data {
        try source.bytes(at: offset, length: length).get()
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

private final class CollectingSink: PacketSink {
    private(set) var packets: [DemuxedPacket] = []
    var isCancelled: Bool { false }
    func accept(_ packet: DemuxedPacket) { packets.append(packet) }
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

    init(cache: SessionBlockCache) throws {
        let source = DemuxerSource(cache: cache)
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
        fileSize = cache.size
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
