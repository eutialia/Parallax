import Foundation
import ParallaxCore

/// One track as AVPlayer sees it: the stream it copies and the clock its samples are timed on.
struct Rendition: Sendable {
    let stream: DemuxedStream
    /// The RFC 6381 string a playlist's `CODECS` carries.
    let codec: String
    /// The Dolby Vision layer a playlist's `SUPPLEMENTAL-CODECS` names, whose record the init
    /// segment then carries: "dvh1.08.06/db1p". Nil for a stream played as it is.
    let supplementalCodec: String?
    let clock: MediaClock
    /// Ticks by which every decode time precedes its rank among the presentation times: the
    /// stream's reorder depth in frames. libavformat refuses a sample that displays before it
    /// decodes, and the lead has to be one value for the whole file, or neighboring segments
    /// would disagree about where one ends and the next begins. Zero for audio.
    let decodeLead: Int64
}

enum RenditionID: Sendable, Equatable {
    case video
    /// A place in the plan's list of audio tracks.
    case audio(Int)
}

/// Why a file cannot go through the bridge. Every reason is known when the file is opened.
public enum BridgeRefusal: Error, Equatable, Sendable {
    /// Fewer than two index entries, so there is nowhere to cut the file into segments.
    case noCues
    case noDuration
    /// A codec, or a profile of one, that the bridge does not deliver or this device does not
    /// decode: "mpeg4 Simple Profile", "h264 High 10", "av1 Main".
    case videoCodec(name: String)
    /// HDR video, "PQ", on a device that shows no HDR: an SDR screen, a mirrored one, an Apple
    /// TV whose output is SDR. AVPlayer refuses an HDR playlist there before it loads a
    /// segment, and a playlist that calls the video SDR fails at its first segment.
    case hdrVideo(range: String)
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
        case .hdrVideo(let range): "video: \(range), and this display shows no HDR"
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
        /// The video's segments cover the file. The audio's stop at the last segment the
        /// audio reaches. That one lasts until the file ends and holds all the audio left.
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
    /// The audio tracks the bridge delivers, in file order. Never empty.
    let audio: [Track]
    /// The place in `audio` of the track that plays when the viewer chose none: the first the
    /// file marks as its default, or the first.
    let defaultAudio: Int
    /// The codecs of the audio tracks the bridge left out: "truehd", "dts DTS-HD MA".
    let omittedAudio: [String]
    /// Bits per second of the densest segment, all streams of the file counted.
    let peakBitrate: Int

    static let videoTimescale: Int64 = 120_000
    /// A segment is at least this long. Index entries closer together are merged.
    static let targetSegmentLength: Int64 = 2_000_000_000
    static let defaultSegmentByteLimit: Int64 = 64 << 20

    func track(_ id: RenditionID) -> Track? {
        switch id {
        case .video: video
        case .audio(let place): audio.indices.contains(place) ? audio[place] : nil
        }
    }

    /// Reads the index and the first segment. Throws a `BridgeRefusal`, the reader's own error,
    /// or the `SegmentWriter.Failure` that stopped an init segment.
    init(
        reading demuxer: MediaDemuxer, support: AVPlayerSupport, showsHDR: Bool,
        segmentByteLimit: Int64 = defaultSegmentByteLimit
    ) async throws {
        let keyframes = try await demuxer.keyframes()
        guard keyframes.count >= 2 else { throw BridgeRefusal.noCues }
        guard let duration = demuxer.duration else { throw BridgeRefusal.noDuration }
        let videoStream = demuxer.streams[demuxer.videoStream]
        guard let videoCodec = videoStream.parameters.playlistCodec, Self.decodes(videoCodec, on: support) else {
            throw BridgeRefusal.videoCodec(name: videoStream.parameters.displayName)
        }
        // HLG plays where HDR does not show, measured on a Mac with an SDR display.
        guard showsHDR || videoStream.parameters.videoRange != "PQ" else {
            throw BridgeRefusal.hdrVideo(range: videoStream.parameters.videoRange)
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
        func packets(of stream: DemuxedStream) -> [DemuxedPacket] { opening.filter { $0.stream == stream.index } }
        func firstTime(of stream: DemuxedStream) -> Int64? { packets(of: stream).compactMap(\.presentationTime).min() }
        guard let videoStart = firstTime(of: videoStream) else { throw SegmentWriter.Failure.untimedSample }
        let audioStreams = demuxer.streams.filter { $0.kind == .audio }
        let delivered = audioStreams.compactMap { stream in
            stream.parameters.playlistCodec.flatMap { codec in
                firstTime(of: stream).map { (stream: stream, codec: codec, start: $0) }
            }
        }
        guard let audioStart = delivered.map(\.start).min() else {
            throw BridgeRefusal.noDeliverableAudio(names: audioStreams.map(\.parameters.displayName))
        }

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
            stream: videoStream, codec: videoCodec, supplementalCodec: videoStream.parameters.dolbyVisionCodec,
            clock: MediaClock(timescale: Self.videoTimescale, origin: origin, grid: videoGrid),
            decodeLead: decodeLead)
        let audioRenditions = delivered.map { stream, codec, start in
            let frame = stream.parameters.samplesPerFrame(readingHeaderOf: packets(of: stream)[0].data)
            return Rendition(
                stream: stream, codec: codec, supplementalCodec: nil,
                clock: MediaClock(
                    timescale: Int64(stream.parameters.sampleRate), origin: origin,
                    grid: frame > 0 ? .init(anchor: start, step: Int64(frame), tolerance: .max) : nil),
                decodeLead: 0)
        }
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
        video = Track(
            rendition: videoRendition,
            initSegment: try SegmentWriter.initSegment(for: videoRendition, describedBy: packets(of: videoStream)),
            segments: segments)
        // AVPlayer waits for good at an audio segment it cannot get, and ends the item where
        // the shorter rendition ends. So a track's list stops at the last segment its audio
        // reaches, and that segment is stretched to the end of the file.
        let last = spans.count - 1
        let reachingTheEnd = try await demuxer.streams(
            Set(delivered.map(\.stream.index)), continuingPastKeyframe: spans[last].lowerBound)
        var audio: [Track] = []
        for rendition in audioRenditions {
            let stream = rendition.stream.index
            let lastWithAudio = reachingTheEnd.contains(stream) ? last : try await Self.lastIndex(below: last) {
                try await demuxer.streams([stream], continuingPastKeyframe: spans[$0].lowerBound) == [stream]
            }
            audio.append(Track(
                rendition: rendition,
                initSegment: try SegmentWriter.initSegment(for: rendition, describedBy: packets(of: rendition.stream)),
                segments: segments[..<lastWithAudio] + [Segment(
                    entries: spans[lastWithAudio],
                    seconds: clock.seconds(at: end) - clock.seconds(at: boundaries[lastWithAudio]), end: end)]))
        }
        self.audio = audio
        defaultAudio = delivered.firstIndex { $0.stream.isDefault } ?? 0
        omittedAudio = audioStreams.filter { stream in !delivered.contains { $0.stream.index == stream.index } }
            .map(\.parameters.displayName)
        peakBitrate = zip(bytes, segments).map { Int(Double($0 * 8) / max($1.seconds, 0.001)) }.max() ?? 0
    }

    /// Whether the device decodes a video codec string the bridge delivers. AV1 and 10-bit
    /// H.264 (profile 110, `6e`) have a decoder on some devices only.
    private static func decodes(_ codec: String, on support: AVPlayerSupport) -> Bool {
        if codec.hasPrefix("av01") { return support.videoCodecs.contains(.av1) }
        if codec.hasPrefix("avc1.6e") { return support.decodesH264High10 }
        return true
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
