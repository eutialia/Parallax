import Foundation

/// One track as AVPlayer sees it: the stream it copies and the clock its samples are timed on.
struct Rendition: Sendable {
    let stream: DemuxedStream
    /// The RFC 6381 string a playlist's `CODECS` carries.
    let codec: String
    let clock: MediaClock
    /// Ticks by which every decode time precedes its rank among the presentation times: the
    /// stream's reorder depth in frames. libavformat refuses a sample that displays before it
    /// decodes, and the lead has to be one value for the whole file, or neighboring segments
    /// would disagree about where one ends and the next begins. Zero for audio.
    let decodeLead: Int64
}

enum RenditionID: String, Sendable, CaseIterable {
    case video = "v"
    case audio = "a"
}

/// Why a file cannot go through the bridge. Every reason is known when the file is opened.
public enum BridgeRefusal: Error, Equatable, Sendable {
    /// Fewer than two index entries, so there is nowhere to cut the file into segments.
    case noCues
    case noDuration
    /// A codec, or a profile of one, that the bridge does not deliver: "mpeg4 Simple Profile",
    /// "h264 High 10".
    case videoCodec(name: String)
    /// No audio stream that is both in a codec the bridge delivers and present at the start of
    /// the file. `names` are the codecs the file does have.
    case noDeliverableAudio(names: [String])
    /// One segment's stretch of the file is larger than a segment may be: it is built in memory.
    case segmentTooLarge(bytes: Int64)
    /// The file's own bytes stopped the bridge: a container libavformat cannot read, no video,
    /// a first sample with no time. `detail` is the failure as the bridge names it.
    case unreadable(detail: String)
}

extension BridgeRefusal: CustomStringConvertible {
    /// One line for the player's error details and the log.
    public var description: String {
        switch self {
        case .noCues: "no keyframe index"
        case .noDuration: "no duration"
        case .videoCodec(let name): "video: \(name)"
        case .noDeliverableAudio(let names): "audio: \(names.isEmpty ? "none" : names.joined(separator: ", "))"
        case .segmentTooLarge(let bytes): "a segment of \(bytes >> 20) MB"
        case .unreadable(let detail): "unreadable: \(detail)"
        }
    }
}

/// Everything AVPlayer is told about a bridged file before it asks for media: the renditions,
/// their init segments, and where every segment starts and ends.
struct BridgePlan: Sendable {
    struct Track: Sendable {
        let rendition: Rendition
        let initSegment: Data
        /// The video's segments cover the file. The audio's stop at the last segment that
        /// holds audio, and that one lasts until the file ends.
        let segments: [Segment]
    }

    /// A run of index entries played as one segment.
    struct Segment: Sendable, Equatable {
        /// The demuxer's span: from the first entry up to, not including, the last.
        let entries: Range<Int>
        let seconds: Double
        /// Nanoseconds in the file's own time: where the next segment starts, or the file ends.
        let end: Int64
    }

    let video: Track
    let audio: Track
    /// Bits per second of the densest segment, all streams of the file counted.
    let peakBitrate: Int

    static let videoTimescale: Int64 = 120_000
    /// A segment is at least this long. Index entries closer together are merged.
    static let targetSegmentLength: Int64 = 2_000_000_000
    static let defaultSegmentByteLimit: Int64 = 64 << 20

    func track(_ id: RenditionID) -> Track {
        switch id {
        case .video: video
        case .audio: audio
        }
    }

    /// Reads the index and the first segment. Throws a `BridgeRefusal`, the reader's own error,
    /// or the `SegmentWriter.Failure` that stopped an init segment.
    init(reading demuxer: MediaDemuxer, segmentByteLimit: Int64 = defaultSegmentByteLimit) async throws {
        let keyframes = try await demuxer.keyframes()
        guard keyframes.count >= 2 else { throw BridgeRefusal.noCues }
        guard let duration = demuxer.duration else { throw BridgeRefusal.noDuration }
        let videoStream = demuxer.streams[demuxer.videoStream]
        guard let videoCodec = videoStream.parameters.playlistCodec else {
            throw BridgeRefusal.videoCodec(name: videoStream.parameters.displayName)
        }

        let starts = keyframes.indices.reduce(into: [Int]()) { starts, index in
            if let last = starts.last, keyframes[index].time - keyframes[last].time < Self.targetSegmentLength { return }
            starts.append(index)
        }
        let spans = zip(starts, starts.dropFirst() + [keyframes.count]).map { $0..<$1 }
        let bytes = spans.map { span in
            (span.upperBound < keyframes.count ? keyframes[span.upperBound].position : demuxer.fileSize)
                - keyframes[span.lowerBound].position
        }
        if let largest = bytes.max(), largest > segmentByteLimit {
            throw BridgeRefusal.segmentTooLarge(bytes: largest)
        }

        let opening = try await demuxer.packets(from: spans[0].lowerBound, to: spans[0].upperBound)
        func firstTime(of stream: Int) -> Int64? {
            opening.lazy.filter { $0.stream == stream }.compactMap(\.presentationTime).min()
        }
        let audioStreams = demuxer.streams.filter { $0.kind == .audio }
        guard let videoStart = firstTime(of: videoStream.index) else { throw SegmentWriter.Failure.untimedSample }
        guard let (audioStream, audioCodec, audioStart) = audioStreams.lazy.compactMap({ stream in
            stream.parameters.playlistCodec.flatMap { codec in firstTime(of: stream.index).map { (stream, codec, $0) } }
        }).first
        else { throw BridgeRefusal.noDeliverableAudio(names: audioStreams.map(\.parameters.displayName)) }

        let videoGrid = videoStream.frameRate.flatMap { rate -> MediaClock.Grid? in
            let (step, remainder) = (Self.videoTimescale * rate.denominator)
                .quotientAndRemainder(dividingBy: rate.numerator)
            return remainder == 0 ? .init(anchor: videoStart, step: step, tolerance: videoStream.tick) : nil
        }
        let frameTicks = videoGrid?.step
            ?? opening.first { $0.stream == videoStream.index }?.duration
                .map { $0 * Self.videoTimescale / 1_000_000_000 }
            ?? 0
        let decodeLead = Int64(videoStream.parameters.reorderDepth) * frameTicks
        // Enough that the earliest decode time and the earliest audio sample are both at or
        // above zero.
        let leadTime = (decodeLead * 1_000_000_000 + Self.videoTimescale - 1) / Self.videoTimescale
        let origin = max(0, leadTime - min(videoStart, audioStart))

        let videoRendition = Rendition(
            stream: videoStream, codec: videoCodec,
            clock: MediaClock(timescale: Self.videoTimescale, origin: origin, grid: videoGrid),
            decodeLead: decodeLead)
        let audioParameters = audioStream.parameters
        let audioRendition = Rendition(
            stream: audioStream, codec: audioCodec,
            clock: MediaClock(
                timescale: Int64(audioParameters.sampleRate), origin: origin,
                grid: audioParameters.samplesPerFrame > 0
                    ? .init(anchor: audioStart, step: Int64(audioParameters.samplesPerFrame), tolerance: .max)
                    : nil),
            decodeLead: 0)
        let clock = videoRendition.clock
        // Muxers disagree on Duration. ffmpeg writes the time the last sample ends; mkvmerge
        // writes the length, which is the same thing only for a file that starts at zero. A
        // value at or before the last segment's start can only be a length.
        let lastStart = keyframes[spans[spans.count - 1].lowerBound].time
        let end = duration > lastStart ? duration : keyframes[0].time + duration
        let boundaries = spans.map { keyframes[$0.lowerBound].time } + [end]
        let segments = zip(spans, zip(boundaries, boundaries.dropFirst())).map {
            Segment(entries: $0, seconds: clock.seconds(at: $1.1) - clock.seconds(at: $1.0), end: $1.1)
        }
        // AVPlayer waits for good at an audio segment it cannot get, and ends the item where
        // the shorter rendition ends. So the audio's list stops at its last segment with
        // audio, and that segment is stretched to the end of the file.
        let lastWithAudio = try await Self.lastIndex(below: spans.count) {
            try await demuxer.holdsPacket(
                of: audioStream.index, from: spans[$0].lowerBound, to: spans[$0].upperBound)
        }
        let audioSegments = segments[..<lastWithAudio] + [Segment(
            entries: spans[lastWithAudio],
            seconds: clock.seconds(at: end) - clock.seconds(at: boundaries[lastWithAudio]), end: end)]
        video = Track(
            rendition: videoRendition,
            initSegment: try SegmentWriter.initSegment(
                for: videoRendition, describedBy: opening.filter { $0.stream == videoStream.index }),
            segments: segments)
        audio = Track(
            rendition: audioRendition,
            initSegment: try SegmentWriter.initSegment(
                for: audioRendition, describedBy: opening.filter { $0.stream == audioStream.index }),
            segments: Array(audioSegments))
        peakBitrate = zip(bytes, segments).map { Int(Double($0 * 8) / max($1.seconds, 0.001)) }.max() ?? 0
    }

    /// The last index `holds` is true for, when it is true at zero and, once false, false to
    /// the end. It asks from the end backwards in doubling steps, because a track that stops
    /// early mostly stops near the end, and a track that does not costs one question.
    private static func lastIndex(below count: Int, where holds: (Int) async throws -> Bool) async throws -> Int {
        var firstWithout = count
        var step = 1
        while firstWithout - step > 0, try await !holds(firstWithout - step) {
            firstWithout -= step
            step *= 2
        }
        var lastWith = max(firstWithout - step, 0)
        while firstWithout - lastWith > 1 {
            let middle = (lastWith + firstWithout) / 2
            if try await holds(middle) { lastWith = middle } else { firstWithout = middle }
        }
        return lastWith
    }
}
