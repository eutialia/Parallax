import AetherLibavcodec
import AetherLibavformat
import AetherLibavutil
import Dispatch
import Foundation
import ParallaxCore
import Synchronization

/// One elementary stream of a container.
struct DemuxedStream: Sendable {
    enum Kind: Sendable, Equatable { case video, audio, subtitle, other }

    let index: Int
    let kind: Kind
    let parameters: CodecParameters
    /// Nanoseconds in one unit of the container's clock for this stream. A stored time is
    /// exact only to this.
    let tick: Int64
    /// Frames per second as the container declares it, or as the spacing of its packets'
    /// times gives it where it declares none. Nil for audio, and when neither says.
    let frameRate: FrameRate?
    /// As the container spells it: "jpn", "en". Nil when it names none.
    let language: String?
    let title: String?
    /// The container marks the stream as the one to play when the viewer chose none.
    let isDefault: Bool
    let packetTimes: PacketTimes

    struct FrameRate: Sendable, Equatable {
        let numerator: Int64
        let denominator: Int64
    }
}

/// What the times a stream's packets carry say of when each frame is shown or heard.
enum PacketTimes: Sendable, Equatable {
    /// Every packet carries the time its frame is shown or heard. The stream may be copied:
    /// a copied frame goes out at the time its packet carries.
    case presentation
    /// Every packet carries the time it is decoded, and the pictures are stored out of the
    /// order they show in. Only a decoder says when each picture shows.
    case decodeOnly
    /// Some packets carry no time, or another frame's.
    case incomplete
}

/// One compressed sample, byte for byte as the container stores it.
struct MediaPacket: Sendable, Equatable {
    let stream: Int
    /// Nanoseconds. Nil when the container gives the sample no time. The decode time, in a
    /// stream whose `packetTimes` are `decodeOnly`.
    let presentationTime: Int64?
    /// Nanoseconds. Nil when the container gives the sample no decode time, and in a container
    /// whose keyframes are known by their presentation time.
    let decodeTime: Int64?
    /// Nanoseconds. Nil when the container gives the sample no length.
    let duration: Int64?
    let isKeyframe: Bool
    let data: Data
}

/// A video keyframe a read can start at.
struct IndexedKeyframe: Sendable, Equatable {
    /// Nanoseconds.
    let time: Int64
    /// Where in the file a read for this keyframe starts.
    let position: Int64
    /// Nanoseconds. Set in a container whose keyframes are known by it.
    let decodeTime: Int64?

    init(time: Int64, position: Int64, decodeTime: Int64? = nil) {
        self.time = time
        self.position = position
        self.decodeTime = decodeTime
    }
}

/// How a demuxer lists the keyframes of a file that has no index.
struct KeyframeListing: Sendable {
    /// A file this size or smaller is read whole, which lists every keyframe. A 138 MB
    /// recording took 2.2 s that way; samples 8 MB apart would have left it 17 keyframes.
    let wholeReadSize: Int64
    let sampling: KeyframeSampler.Limits
    /// Told of each packet the listing reads.
    let progress: ListingProgress?
    /// Whether the time for sampling is up. Sampling then goes on only where a segment would
    /// be larger than the largest one.
    let timeIsUp: @Sendable () -> Bool

    init(
        wholeReadSize: Int64 = 256 << 20, sampling: KeyframeSampler.Limits = .standard,
        progress: ListingProgress? = nil, timeIsUp: @escaping @Sendable () -> Bool = { false }
    ) {
        self.wholeReadSize = wholeReadSize
        self.sampling = sampling
        self.progress = progress
        self.timeIsUp = timeIsUp
    }
}

/// How far the read that lists a file's keyframes has come, so a deadline can tell a long read
/// from a stuck one.
final class ListingProgress: Sendable {
    private let packets = Atomic(0)

    var packetsRead: Int { packets.load(ordering: .relaxed) }

    func readPacket() {
        packets.add(1, ordering: .relaxed)
    }
}

/// Takes one read's packets, on the demuxer's queue, which it may block.
protocol PacketSink: AnyObject {
    /// Checked between packets: a read whose sink is cancelled stops with `CancellationError`.
    var isCancelled: Bool { get }
    /// Whether the read may stop at the end of its span. A sink that decodes says no until it
    /// has the span's last sample, which a decoder may give only when handed a later packet.
    var isSatisfied: Bool { get }
    func accept(_ packet: MediaPacket) throws
}

extension PacketSink {
    var isSatisfied: Bool { true }
}

/// A container opened through libavformat, read in spans between listed keyframes.
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
        /// A container the bridge has no rules for reading in spans. `name` is libavformat's:
        /// "rm".
        case unbridgedContainer(name: String)
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
    private nonisolated let container: BridgedContainer
    private let source: DemuxerSource
    private let context: UnsafeMutablePointer<AVFormatContext>
    private let packet: UnsafeMutablePointer<AVPacket>
    /// Nanoseconds: the first timestamp of the file, as libavformat reports it.
    private nonisolated let start: Int64
    private let listing: KeyframeListing
    private var listed: [IndexedKeyframe]?
    /// Where the last packet read from each stream ends, in the stream's ticks, since the last
    /// seek.
    private var packetEnds: [Int32: Int64] = [:]
    /// Where the last packet read from each audio stream ends by the time libavformat gave it,
    /// in the stream's ticks, since the last seek.
    private var timedAudioEnds: [Int32: Int64] = [:]

    nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    /// What this demuxer's reads have fetched from the reader, rather than found kept.
    var bytesFetched: Int { source.bytesFetched }

    /// A demuxer with blocks of its own.
    static func open(_ reader: any RandomAccessReading) async throws -> MediaDemuxer {
        try await open(SessionBlockCache(reader: reader, size: try await reader.fileSize))
    }

    /// A demuxer over blocks other demuxers of the file share. With `keyframes`, the list one
    /// of them made, it makes none of its own.
    static func open(
        _ cache: SessionBlockCache, keyframes: [IndexedKeyframe]? = nil, listing: KeyframeListing = .init()
    ) async throws -> MediaDemuxer {
        let queue = DispatchSerialQueue(label: "parallax.media-demuxer", qos: .userInitiated)
        let opened = try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: Result { try Opened(cache: cache) })
            }
        }
        return MediaDemuxer(opened, keyframes: keyframes, listing: listing, queue: queue)
    }

    private init(
        _ opened: sending Opened, keyframes: [IndexedKeyframe]?, listing: KeyframeListing, queue: DispatchSerialQueue
    ) {
        self.queue = queue
        container = opened.container
        source = opened.source
        context = opened.context
        packet = opened.packet
        streams = opened.streams
        videoStream = opened.videoStream
        duration = opened.duration
        fileSize = opened.fileSize
        start = opened.start
        self.listing = listing
        listed = keyframes
    }

    isolated deinit {
        var packet: UnsafeMutablePointer<AVPacket>? = packet
        av_packet_free(&packet)
        let io = context.pointee.pb
        var context: UnsafeMutablePointer<AVFormatContext>? = context
        avformat_close_input(&context)
        DemuxerSource.free(io)
    }

    /// The time the file ends, in nanoseconds of its own time. `duration` is this demuxer's.
    nonisolated func end(of duration: Int64, lastSegmentStart: Int64, firstKeyframe: Int64) -> Int64 {
        container.end(
            of: duration, startingAt: start, lastSegmentStart: lastSegmentStart, firstKeyframe: firstKeyframe)
    }

    /// The video keyframes a span can start at, in file order. A file with no index is read
    /// for them: whole, or in samples when it is large and a read may start at any packet.
    /// The first call makes the list.
    func keyframes() throws -> [IndexedKeyframe] {
        if let listed { return listed }
        let made = switch container.spanStart {
        case .indexEntry: try indexedKeyframes()
        case .packet where fileSize > listing.wholeReadSize: try sampledKeyframes().listed()
        case .packet, .packetReadFromTheStart: try everyKeyframe().listed()
        }
        listed = made
        return made
    }

    /// The keyframes of the video stream's index as the container stores it. Matroska loads
    /// its Cues on the first seek.
    private func indexedKeyframes() throws -> [IndexedKeyframe] {
        try seek(toVideoTick: 0)
        // The seek reports success when the read of the Cues failed, and the index is then
        // short or empty.
        if let failure = source.takeFailure() { throw failure }
        let stream = context.pointee.streams[videoStream]
        return (0..<avformat_index_get_entries_count(stream)).compactMap { index in
            avformat_index_get_entry(stream, index).flatMap {
                $0.pointee.flags & AVINDEX_KEYFRAME == 0 ? nil : IndexedKeyframe(
                    time: nanoseconds($0.pointee.timestamp, of: videoStream), position: $0.pointee.pos)
            }
        }
    }

    private func everyKeyframe() throws -> [IndexedKeyframe] {
        switch container.seek {
        case .byte: try seek(toByte: 0)
        // A byte seek to the start of an ASF read on from past its first keyframe. A program
        // stream's keyframes were listed from the same seek.
        case .time, .timeBeforeDecodeTime: try seek(toVideoTick: 0)
        }
        var found: [IndexedKeyframe] = []
        while let keyframe = try nextKeyframe(before: fileSize) { found.append(keyframe) }
        return found
    }

    private func sampledKeyframes() throws -> [IndexedKeyframe] {
        let sampler = KeyframeSampler(fileSize: fileSize, limits: listing.sampling)
        var samples: [KeyframeSampler.Sample] = []
        while let range = sampler.nextRange(after: samples, timeIsUp: listing.timeIsUp()) {
            try seek(toByte: range.lowerBound)
            samples.append(.init(searched: range, keyframe: try nextKeyframe(before: range.upperBound)))
        }
        return samples.compactMap(\.keyframe)
    }

    /// The next video keyframe the read comes to, nil when a video packet at or past `limit`
    /// or the end of the file comes first. Only the video's packets come in the order they
    /// are stored. A keyframe with no time cannot bound a span, and one with no position is
    /// not where a read can start.
    private func nextKeyframe(before limit: Int64) throws -> IndexedKeyframe? {
        while let packet = try nextPacket() {
            defer { av_packet_unref(packet) }
            try Task.checkCancellation()
            listing.progress?.readPacket()
            guard Int(packet.pointee.stream_index) == videoStream, packet.pointee.pos >= 0 else { continue }
            if packet.pointee.pos >= limit { return nil }
            guard packet.pointee.flags & AV_PKT_FLAG_KEY != 0, let time = time(of: packet) else { continue }
            guard findsKeyframesByDecodeTime else { return IndexedKeyframe(time: time, position: packet.pointee.pos) }
            if let decodeTime = decodeTime(of: packet) {
                return IndexedKeyframe(time: time, position: packet.pointee.pos, decodeTime: decodeTime)
            }
        }
        return nil
    }

    /// The packets of `stream` in the span that starts at keyframe `lower` and ends before
    /// keyframe `upper`, in file order, handed to `sink` as they are read. `upper` equal to the
    /// keyframe count reads to the end of the file.
    ///
    /// Video belongs to the span by position: every packet from the lower keyframe up to the
    /// upper one, so pictures that display before their keyframe stay with it. A sink that is
    /// not satisfied at the upper keyframe is handed the packets after it until it is. Audio
    /// belongs by time: every packet timed in `[lower, upper)`. The first span also takes
    /// whatever is timed before its keyframe. Neighboring spans therefore share no packet and
    /// drop none.
    ///
    /// With `takingLaterAudio`, audio has no upper time: the span also takes the audio timed
    /// after it that the read comes by. That is for the span an audio track ends in.
    ///
    /// An audio frame is timed by where `clock` starts the MP4 sample it goes into, so frames
    /// the muxer joins stay in one span.
    ///
    /// With `warmUp`, audio is handed over from that many nanoseconds before the span, and on
    /// past its end until the sink is satisfied: what a sink that decodes needs.
    func read<Sink: PacketSink>(
        _ stream: Int, from lower: Int, to upper: Int, takingLaterAudio: Bool = false, clock: MediaClock? = nil,
        warmUp: Int64 = 0, into sink: Sink
    ) throws {
        let keyframes = try keyframes()
        precondition(keyframes.indices.contains(lower) && lower < upper && upper <= keyframes.count)
        let lowerTime = lower == 0 ? Int64.min : keyframes[lower].time
        let upperTime = upper == keyframes.count ? Int64.max : keyframes[upper].time
        if stream == videoStream {
            // A video span needs nothing stored before its keyframe, and a listed keyframe is
            // where a read can start.
            try seek(to: keyframes[lower])
            try readVideo(
                from: lower == 0 ? Int64.min : spanTime(of: keyframes[lower]),
                to: upper == keyframes.count ? Int64.max : spanTime(of: keyframes[upper]), into: sink)
            return
        }
        let audioUpperTime = takingLaterAudio ? Int64.max : upperTime
        let earliest = lower == 0 ? Int64.min : lowerTime - warmUp
        // The listed keyframe no read starts before: the span's own, or the last one the
        // warm-up starts at or after.
        let first = warmUp == 0 ? lower : keyframes[...lower].lastIndex { $0.time <= earliest } ?? 0
        guard case .before(let search) = container.audioPlacement else {
            // A seek that goes by time takes the warm-up itself. The listed keyframe before a
            // sampled one may be a segment away.
            if case .timeBeforeDecodeTime = container.seek {
                try seek(to: keyframes[lower], warmUp: warmUp)
            } else {
                try seek(to: keyframes[first])
            }
            _ = try readAudio(
                stream, from: earliest, to: audioUpperTime, videoEnd: upperTime, clock: clock,
                startedEarlyEnough: true, into: sink)
            return
        }
        // Audio may be stored ahead of the keyframe it plays with, so the read starts earlier.
        // The last place it can start is the previous listed keyframe, which may be a long
        // span back.
        let floor = keyframes[..<first].last { $0.position < keyframes[first].position }?.position
            ?? keyframes[first].position
        // The search goes back from the span's own keyframe, and by the warm-up's share of the
        // bytes before it: the listed keyframe before may be a segment of 256 MB away.
        var back = lower == 0 ? 0
            : audioLookback(search, before: keyframes[lower], after: keyframes[lower - 1])
                + Self.bytes(lasting: warmUp, before: keyframes[lower], after: keyframes[lower - 1])
        while true {
            let from = keyframes[lower].position - back
            let start = from <= floor ? nil
                : try audioReadStart(search, from: from, before: keyframes[lower], after: keyframes[max(first - 1, 0)])
            // A cluster may run 32 s: with none this close, one further back is still nearer
            // than the floor.
            if start == nil, from > floor {
                back *= 2
                continue
            }
            try seek(toByte: start ?? floor)
            let tookItAll = try readAudio(
                stream, from: earliest, to: audioUpperTime, videoEnd: upperTime, clock: clock,
                startedEarlyEnough: start == nil, into: sink)
            if tookItAll { return }
            back *= 2
        }
    }

    /// `read`'s packets, collected.
    func packets(
        _ stream: Int, from lower: Int, to upper: Int, takingLaterAudio: Bool = false, clock: MediaClock? = nil,
        warmUp: Int64 = 0
    ) throws -> [MediaPacket] {
        let collected = CollectingSink()
        try read(
            stream, from: lower, to: upper, takingLaterAudio: takingLaterAudio, clock: clock, warmUp: warmUp,
            into: collected)
        return collected.packets
    }

    /// Every packet of every audio and video stream of span `lower..<upper`, the video first.
    /// For tests and the library sweep, which compare a span with its source.
    func packets(from lower: Int, to upper: Int, takingLaterAudio: Bool = false) throws -> [MediaPacket] {
        try ([videoStream] + streams.filter { $0.kind == .audio }.map(\.index)).flatMap {
            try packets($0, from: lower, to: upper, takingLaterAudio: takingLaterAudio)
        }
    }

    /// The first span's video and audio packets, in file order, up to the first of: `videoPackets`
    /// video packets, `audioPackets` of each stream in `audio` and `audioSpan` nanoseconds of
    /// each stream in `spanned`; `byteLimit` bytes from the first keyframe; keyframe `upper`.
    /// What a plan needs to describe the streams and place them in time, without reading a
    /// first span that may be hundreds of megabytes.
    func opening(
        before upper: Int, videoPackets: Int, audioPackets: Int, of audio: Set<Int>, audioSpan: Int64 = 0,
        of spanned: Set<Int> = [], byteLimit: Int
    ) throws -> [MediaPacket] {
        let keyframes = try keyframes()
        let upperTime = upper == keyframes.count ? Int64.max : keyframes[upper].time
        try seek(to: keyframes[0])
        var collected: [MediaPacket] = []
        var counts: [Int: Int] = [:]
        var spans: [Int: (first: Int64, last: Int64)] = [:]
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
            if let time = demuxed.presentationTime { spans[stream] = (spans[stream]?.first ?? time, time) }
            if started { bytes += demuxed.data.count }
            let enough = counts[videoStream, default: 0] >= videoPackets
                && audio.allSatisfy { counts[$0, default: 0] >= audioPackets }
                && spanned.allSatisfy { spans[$0].map { $0.last - $0.first >= audioSpan } == true }
            if enough || bytes > byteLimit { break }
        }
        return collected
    }

    /// The read goes on past the upper keyframe while the sink is not satisfied, up to the
    /// first keyframe `videoRunOn` later: a decoder that gives nothing more must not read the
    /// rest of the file.
    private func readVideo(from lowerTime: Int64, to upperTime: Int64, into sink: some PacketSink) throws {
        var started = false
        var passedUpper = false
        while let packet = try nextPacket() {
            defer { av_packet_unref(packet) }
            if sink.isCancelled { throw CancellationError() }
            if passedUpper, sink.isSatisfied { return }
            guard Int(packet.pointee.stream_index) == videoStream else { continue }
            if packet.pointee.flags & AV_PKT_FLAG_KEY != 0, let time = spanTime(of: packet) {
                if time >= upperTime {
                    if sink.isSatisfied || time - upperTime >= Self.videoRunOn { return }
                    passedUpper = true
                }
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
                    if time >= upperTime, sink.isSatisfied { return true }
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

    /// How far before `keyframe` an audio read first starts, or first looks for a place to.
    private func audioLookback(
        _ search: BridgedContainer.AudioSearch, before keyframe: IndexedKeyframe, after previous: IndexedKeyframe
    ) -> Int64 {
        switch search {
        case .matroskaClusters: Self.audioLookback(before: keyframe, after: previous)
        case .bytesBefore(let bytes), .flashVideoTags(let bytes): bytes
        }
    }

    /// Where a read from `offset` or later can begin. Nil when it can begin nowhere before
    /// `keyframe`.
    private func audioReadStart(
        _ search: BridgedContainer.AudioSearch, from offset: Int64, before keyframe: IndexedKeyframe,
        after previous: IndexedKeyframe
    ) throws -> Int64? {
        switch search {
        case .matroskaClusters: try clusterStart(from: offset, before: keyframe, after: previous.time)
        case .bytesBefore: offset
        case .flashVideoTags: try tagStart(atOrBefore: offset, before: keyframe)
        }
    }

    /// The start of the last tag at or before `offset`, found by stepping back from
    /// `keyframe`'s: the four bytes before a tag are the size of the one before it. Nil when
    /// a size is not one a tag can have, as in a file written without them.
    func tagStart(atOrBefore offset: Int64, before keyframe: IndexedKeyframe) throws -> Int64? {
        // A file starts with nine bytes of header and a size of zero, and a tag with eleven.
        let firstTag: Int64 = 13
        var at = keyframe.position
        while at > offset, at > firstTag {
            let size = try bytes(at: at - 4, length: 4).reduce(Int64(0)) { $0 << 8 | Int64($1) }
            guard size >= 11, at - 4 - size >= firstTag else { return nil }
            at -= 4 + size
        }
        return at
    }

    /// The bytes `duration` nanoseconds take at the average rate of the index span before
    /// `keyframe`.
    static func bytes(lasting duration: Int64, before keyframe: IndexedKeyframe, after previous: IndexedKeyframe) -> Int64 {
        let bytes = Double(keyframe.position - previous.position)
        return Int64(bytes * Double(duration) / Double(max(keyframe.time - previous.time, 1)))
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
        try seek(to: keyframe)
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

    /// The next packet of a stream the demuxer described at open, or nil at the end of the
    /// file. The caller unrefs it.
    ///
    /// libavformat adds a stream to a program stream when its first packet turns up. One that
    /// shows up past what it read at open, as a DVD's subtitles do, is in no plan.
    private func nextPacket() throws -> UnsafeMutablePointer<AVPacket>? {
        while true {
            var status = av_read_frame(context, packet)
            // The transport stream reader answers this where it finds no packet in the 64 KB
            // after a damaged one. The next call reads on from there.
            while status == DemuxerSource.Code.tryAgain, !source.hasFailed {
                status = av_read_frame(context, packet)
            }
            if status == DemuxerSource.Code.endOfFile, !source.hasFailed { return nil }
            try check(status)
            guard streams.indices.contains(Int(packet.pointee.stream_index)) else {
                av_packet_unref(packet)
                continue
            }
            timeFromThePacketBefore(packet)
            timeFromTheFrameBefore(packet)
            return packet
        }
    }

    /// libavformat gives no time to the second H.264 packet it reads after a seek in an ASF
    /// (each of 4 seeks in a synthetic file; a read with no seek before it timed all 288). In
    /// a container that stores decode times, that packet starts where the one before it ends.
    private func timeFromThePacketBefore(_ packet: UnsafeMutablePointer<AVPacket>) {
        guard !container.storesPresentationTimes else { return }
        let stream = packet.pointee.stream_index
        if packet.pointee.pts == Self.noTime, packet.pointee.dts == Self.noTime, let end = packetEnds[stream] {
            packet.pointee.dts = end
        }
        packetEnds[stream] = packet.pointee.dts == Self.noTime || packet.pointee.duration <= 0
            ? nil : packet.pointee.dts + packet.pointee.duration
    }

    /// In a container that times split audio frames late, a frame timed a whole frame after the
    /// one before it ends starts where that one ends. A frame after a hole exactly its own
    /// length is moved into the hole, which then follows it.
    private func timeFromTheFrameBefore(_ packet: UnsafeMutablePointer<AVPacket>) {
        let stream = packet.pointee.stream_index
        guard container.timesSplitAudioFramesLate, streams[Int(stream)].kind == .audio else { return }
        let timed = packet.pointee.pts
        let length = packet.pointee.duration
        if let end = timedAudioEnds[stream], timed == end + length {
            packet.pointee.pts = end
        }
        timedAudioEnds[stream] = timed == Self.noTime || length <= 0 ? nil : timed + length
    }

    private func time(of packet: UnsafeMutablePointer<AVPacket>) -> Int64? {
        let stream = Int(packet.pointee.stream_index)
        // libavformat gives a presentation time to some pictures of a stream it has only
        // decode times for, the B-pictures of MPEG-4 in an AVI. Such a stream is placed by its
        // decode times throughout.
        if packet.pointee.pts != Self.noTime, streams[stream].packetTimes != .decodeOnly {
            return nanoseconds(packet.pointee.pts, of: stream)
        }
        guard !container.storesPresentationTimes, packet.pointee.dts != Self.noTime else { return nil }
        return nanoseconds(packet.pointee.dts, of: stream)
    }

    private var findsKeyframesByDecodeTime: Bool { container.findsKeyframesByDecodeTime }

    /// The time a video span is bounded by: a keyframe's as listed, and a packet's as read.
    private func spanTime(of keyframe: IndexedKeyframe) -> Int64 {
        findsKeyframesByDecodeTime ? keyframe.decodeTime ?? keyframe.time : keyframe.time
    }

    private func spanTime(of packet: UnsafeMutablePointer<AVPacket>) -> Int64? {
        findsKeyframesByDecodeTime ? decodeTime(of: packet) : time(of: packet)
    }

    private func decodeTime(of packet: UnsafeMutablePointer<AVPacket>) -> Int64? {
        packet.pointee.dts == Self.noTime ? nil : nanoseconds(packet.pointee.dts, of: Int(packet.pointee.stream_index))
    }

    /// Nil for a packet that carries no bytes.
    private func demuxed(_ packet: UnsafeMutablePointer<AVPacket>) -> MediaPacket? {
        let stream = Int(packet.pointee.stream_index)
        return packet.pointee.data.map { bytes in
            MediaPacket(
                stream: stream, presentationTime: time(of: packet),
                decodeTime: findsKeyframesByDecodeTime ? decodeTime(of: packet) : nil,
                duration: packet.pointee.duration > 0 ? nanoseconds(packet.pointee.duration, of: stream) : nil,
                isKeyframe: packet.pointee.flags & AV_PKT_FLAG_KEY != 0,
                data: Data(bytes: bytes, count: Int(packet.pointee.size)))
        }
    }

    private func seek(to keyframe: IndexedKeyframe, warmUp: Int64 = 0) throws {
        switch container.seek {
        case .byte: try seek(toByte: keyframe.position)
        case .time:
            try seek(toVideoTick: av_rescale_q(keyframe.time, Self.nanoseconds, timeBase(of: videoStream)))
        case .timeBeforeDecodeTime(let lead):
            // The first span takes what is stored before its keyframe, from the seek the
            // keyframes were listed from.
            let time = keyframe == listed?.first ? 0 : spanTime(of: keyframe) - warmUp - lead
            try seek(toVideoTick: av_rescale_q(time, Self.nanoseconds, timeBase(of: videoStream)))
        }
    }

    private func seek(toVideoTick tick: Int64) throws {
        packetEnds = [:]
        timedAudioEnds = [:]
        try check(av_seek_frame(context, Int32(videoStream), tick, AVSEEK_FLAG_BACKWARD))
    }

    /// Reading on from a byte seek in Matroska relies on FFmpegBuild's matroska-byte-seek-done
    /// patch. A seek by time in Matroska would make libavformat drop what precedes the keyframe
    /// it lands on.
    private func seek(toByte position: Int64) throws {
        packetEnds = [:]
        timedAudioEnds = [:]
        try check(av_seek_frame(context, -1, position, AVSEEK_FLAG_BYTE))
    }

    private func bytes(at offset: Int64, length: Int) throws -> Data {
        try source.bytes(at: offset, length: length).get()
    }

    private static let audioSearchLimit = 4 << 20
    /// Nanoseconds a video read goes on past its span for a sink that decodes. A decoder holds
    /// back the pictures it is still reordering and those its threads are working on, a second
    /// of video at most.
    private static let videoRunOn: Int64 = 2_000_000_000
    /// Nanoseconds. Muxers store a stream's packets within a cluster of the video they play
    /// with, and a cluster holds five seconds at most.
    private static let interleaveLimit: Int64 = 5_000_000_000
    private static let nanoseconds = AVRational(num: 1, den: 1_000_000_000)
    /// `AV_NOPTS_VALUE`, which does not import into Swift.
    fileprivate static let noTime = Int64.min

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
    private(set) var packets: [MediaPacket] = []
    var isCancelled: Bool { false }
    func accept(_ packet: MediaPacket) { packets.append(packet) }
}

/// What opening a container produces, built on the demuxer's queue before the actor exists.
private struct Opened {
    let container: BridgedContainer
    let source: DemuxerSource
    let context: UnsafeMutablePointer<AVFormatContext>
    let packet: UnsafeMutablePointer<AVPacket>
    let streams: [DemuxedStream]
    let videoStream: Int
    let duration: Int64?
    let start: Int64
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
        let format = context?.pointee.iformat.map { String(cString: $0.pointee.name) } ?? ""
        let bridged = BridgedContainer(formatName: format)
        if status >= 0 {
            if let bridged { context?.pointee.probesize = bridged.analysisLimit }
            status = avformat_find_stream_info(context, nil)
        }
        let video = status >= 0 ? av_find_best_stream(context, AVMEDIA_TYPE_VIDEO, -1, -1, nil, 0) : -1

        // libavformat takes a failed read while it describes the streams for the end of the
        // file and reports success.
        let failure = source.takeFailure()
        guard let context, failure == nil, status >= 0, let bridged, video >= 0 else {
            var packet: UnsafeMutablePointer<AVPacket>? = packet
            av_packet_free(&packet)
            avformat_close_input(&context)
            DemuxerSource.free(io)
            if let failure { throw failure }
            if status < 0 { throw MediaDemuxer.OpenFailure.unreadableContainer(code: status) }
            if bridged == nil { throw MediaDemuxer.OpenFailure.unbridgedContainer(name: format) }
            throw MediaDemuxer.OpenFailure.noVideoStream
        }

        container = bridged
        self.source = source
        self.context = context
        self.packet = packet
        videoStream = Int(video)
        fileSize = cache.size
        // `AV_TIME_BASE` units, which are microseconds. A duration libavformat worked out from
        // the bitrate is a guess, and a file's end cannot be placed by one.
        duration = context.pointee.duration > 0 && context.pointee.duration_estimation_method != AVFMT_DURATION_FROM_BITRATE
            ? context.pointee.duration * 1000 : nil
        start = context.pointee.start_time == MediaDemuxer.noTime ? 0 : context.pointee.start_time * 1000
        let nanoseconds = AVRational(num: 1, den: 1_000_000_000)
        // A transport stream may carry several programs, and only the video's own streams play
        // with it. A file with no programs has none to tell apart.
        let program = av_find_program_from_stream(context, nil, video)?.pointee.id
        func playsWithTheVideo(_ index: Int) -> Bool {
            program == nil || av_find_program_from_stream(context, nil, Int32(index))?.pointee.id == program
        }
        let described = (0..<Int(context.pointee.nb_streams)).map { index -> DemuxedStream? in
            guard let stream = context.pointee.streams[index]?.pointee,
                  let parameters = CodecParameters(copying: stream.codecpar)
            else { return nil }
            let kind: DemuxedStream.Kind = switch stream.codecpar.pointee.codec_type {
            case _ where !playsWithTheVideo(index): .other
            case AVMEDIA_TYPE_VIDEO: .video
            case AVMEDIA_TYPE_AUDIO: .audio
            case AVMEDIA_TYPE_SUBTITLE: .subtitle
            default: .other
            }
            let rate = bridged.declaresFrameRate ? stream.avg_frame_rate : stream.r_frame_rate
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
                isDefault: stream.disposition & AV_DISPOSITION_DEFAULT != 0,
                packetTimes: !bridged.storesPresentationTimes && parameters.reorderDepth > 0 ? .decodeOnly
                    // A keyframe read after a seek may carry no presentation time.
                    : kind == .video && bridged.findsKeyframesByDecodeTime ? .incomplete : .presentation)
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
