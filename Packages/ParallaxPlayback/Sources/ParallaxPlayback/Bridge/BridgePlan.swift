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
    /// Fewer than two keyframes a read can start at, so there is nowhere to cut the file into
    /// segments.
    case noCues
    case noDuration
    /// A codec, or a profile of one, that the bridge does not deliver or this device does not
    /// decode: "mpeg4 Simple Profile", "h264 High 10", "av1 Main".
    case videoCodec(name: String)
    /// HDR video, "PQ", on a device that shows no HDR: an SDR screen, a mirrored one, an Apple
    /// TV whose output is SDR. AVPlayer refuses an HDR playlist there before it loads a
    /// segment, and a playlist that calls the video SDR fails at its first segment.
    case hdrVideo(range: String)
    /// Video stored as fields. AVPlayer shows it combed or black, and joining the fields into
    /// pictures is decoding.
    case interlacedVideo
    /// No audio stream that is both in a codec the bridge delivers and present at the start of
    /// the file. `names` are the codecs the file does have, of the video's own program.
    case noDeliverableAudio(names: [String])
    /// The index stops: after its last entry more of the file runs than any keyframe interval
    /// does, with nowhere to start a segment. `after` is that entry, in whole seconds from the
    /// first keyframe.
    case indexGap(after: Int)
    /// Video whose packets carry no presentation time and are stored out of the order they
    /// show in, as H.264 with B-frames is in an AVI.
    case untimedVideo
    /// The codecs are ones the bridge delivers, in a container it cannot read in spans.
    /// `name` is libavformat's: "asf", "mpeg".
    case container(name: String)
    /// The file's times go back part way through, as in two recordings joined into one file.
    /// `after` is the last keyframe before that, in whole seconds from the first.
    case timestampsRestart(after: Int)
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
        case .interlacedVideo: "video: interlaced"
        case .noDeliverableAudio(let names): "audio: \(names.isEmpty ? "none" : names.joined(separator: ", "))"
        case .indexGap(let after):
            "no keyframe index after \(Self.clockTime(after))"
        case .untimedVideo: "video: no presentation times"
        case .container(let name): "container: \(name)"
        case .timestampsRestart(let after): "timestamps restart after \(Self.clockTime(after))"
        case .unreadable(let detail): "unreadable: \(detail)"
        }
    }

    private static func clockTime(_ seconds: Int) -> String {
        "\(seconds / 3600):\(String(format: "%02d:%02d", seconds / 60 % 60, seconds % 60))"
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
    /// Longer than any keyframe interval a real encode has: the longest in a 74-movie library
    /// was 282 s, and the file whose index stops ran 5,401 s past its last entry.
    static let defaultIndexGapLimit: Duration = .seconds(600)

    /// How far into the first span the plan reads for an audio stream to show. Audio that starts
    /// with the video is in the first cluster; a stream that has shown nothing by here is left
    /// out. The first span of a measured movie was 224 MB, too much to read inside the open's
    /// deadline.
    static let openingByteLimit = 16 << 20

    func track(_ id: RenditionID) -> Track? {
        switch id {
        case .video: video
        case .audio(let place): audio.indices.contains(place) ? audio[place] : nil
        }
    }

    /// Decides what to do with the video and the audio from what the streams say, then reads the
    /// keyframe list and the file's opening: a file refused for a codec costs no read past its
    /// headers. Throws a `BridgeRefusal`, the reader's own error, or the `SegmentWriter.Failure`
    /// that stopped an init segment.
    init(
        reading demuxer: MediaDemuxer, support: AVPlayerSupport, showsHDR: Bool,
        indexGapLimit: Duration = defaultIndexGapLimit
    ) async throws {
        let videoStream = demuxer.streams[demuxer.videoStream]
        let videoCodec: String
        switch VideoDecision(for: videoStream, on: support, showingHDR: showsHDR) {
        case .copy(let codec): videoCodec = codec
        case .refuse(let refusal): throw refusal
        }
        guard demuxer.timesItsPictures else { throw BridgeRefusal.untimedVideo }

        let audioStreams = demuxer.streams.filter { $0.kind == .audio }
        let noDeliverableAudio = BridgeRefusal.noDeliverableAudio(names: audioStreams.map(\.parameters.displayName))
        guard audioStreams.contains(where: { $0.parameters.playlistCodec != nil }) else { throw noDeliverableAudio }

        let keyframes = try await demuxer.keyframes()
        guard keyframes.count >= 2 else { throw BridgeRefusal.noCues }
        guard let duration = demuxer.duration else { throw BridgeRefusal.noDuration }

        let cuts = try SegmentCuts(at: keyframes, fileSize: demuxer.fileSize, indexGapLimit: indexGapLimit) {
            lastSegmentStart in
            demuxer.end(of: duration, lastSegmentStart: lastSegmentStart, firstKeyframe: keyframes[0].time)
        }

        // The earliest picture shown is within the reorder depth of the keyframe, and audio
        // runs in time order. An init segment is written from one MP4 sample, which may join
        // several frames.
        let opening = try await demuxer.opening(
            before: cuts.spans[0].upperBound, videoPackets: videoStream.parameters.reorderDepth + 1,
            audioPackets: CodecParameters.mostFramesPerSample,
            of: Set(audioStreams.filter { $0.parameters.playlistCodec != nil }.map(\.index)),
            byteLimit: Self.openingByteLimit)
        func packets(of stream: DemuxedStream) -> [DemuxedPacket] { opening.filter { $0.stream == stream.index } }
        guard let videoStart = packets(of: videoStream).compactMap(\.presentationTime).min() else {
            throw SegmentWriter.Failure.untimedSample
        }

        let audioDecisions = audioStreams.map { AudioDecision(for: $0, openingWith: packets(of: $0)) }
        let copiedAudio = audioDecisions.compactMap(\.copied)
        guard let audioStart = copiedAudio.map(\.start).min() else { throw noDeliverableAudio }

        let pacing = VideoPacing(of: videoStream, startingAt: videoStart, firstPacket: packets(of: videoStream).first)
        // Enough that the earliest decode time and the earliest audio sample are both at or
        // above zero.
        let leadTime = (pacing.decodeLead * 1_000_000_000 + Self.videoTimescale - 1) / Self.videoTimescale
        let origin = max(0, leadTime - min(videoStart, audioStart))

        let videoRendition = Rendition(
            stream: videoStream, codec: videoCodec, supplementalCodec: videoStream.parameters.dolbyVisionCodec,
            clock: MediaClock(timescale: Self.videoTimescale, origin: origin, grid: pacing.grid),
            decodeLead: pacing.decodeLead)
        let audioRenditions = copiedAudio.map { $0.rendition(origin: origin) }

        let segments = cuts.segments(on: videoRendition.clock)
        video = Track(
            rendition: videoRendition,
            initSegment: try SegmentWriter.initSegment(for: videoRendition, describedBy: packets(of: videoStream)),
            segments: segments)
        // AVPlayer waits for good at an audio segment it cannot get, and ends the item where
        // the shorter rendition ends. So a track's list stops at the last segment its audio
        // reaches, and that segment is stretched to the end of the file.
        let last = cuts.spans.count - 1
        let audioClocks = Dictionary(uniqueKeysWithValues: audioRenditions.map { ($0.stream.index, $0.clock) })
        let reachingTheEnd = try await demuxer.streams(audioClocks, continuingPastKeyframe: cuts.spans[last].lowerBound)
        var audio: [Track] = []
        for rendition in audioRenditions {
            let stream = rendition.stream.index
            let lastWithAudio = reachingTheEnd.contains(stream) ? last : try await Self.lastIndex(below: last) {
                try await demuxer.streams([stream: rendition.clock], continuingPastKeyframe: cuts.spans[$0].lowerBound) == [stream]
            }
            audio.append(Track(
                rendition: rendition,
                initSegment: try SegmentWriter.initSegment(for: rendition, describedBy: packets(of: rendition.stream)),
                segments: segments[..<lastWithAudio] + [cuts.segment(from: lastWithAudio, on: videoRendition.clock)]))
        }
        self.audio = audio
        defaultAudio = copiedAudio.firstIndex { $0.stream.isDefault } ?? 0
        omittedAudio = audioDecisions.compactMap(\.omitted)
        peakBitrate = zip(cuts.bytes, segments).map { Int(Double($0 * 8) / max($1.seconds, 0.001)) }.max() ?? 0
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

/// What the bridge does with a file's video stream, decided from what the stream says of itself
/// and what the device decodes and shows.
enum VideoDecision {
    /// Delivered byte for byte, under this RFC 6381 codec string.
    case copy(codec: String)
    case refuse(BridgeRefusal)

    init(for stream: DemuxedStream, on support: AVPlayerSupport, showingHDR: Bool) {
        guard let codec = stream.parameters.playlistCodec, Self.decodes(codec, on: support) else {
            self = .refuse(.videoCodec(name: stream.parameters.displayName))
            return
        }
        guard !stream.parameters.isInterlaced else {
            self = .refuse(.interlacedVideo)
            return
        }
        // HLG plays where HDR does not show, measured on a Mac with an SDR display.
        guard showingHDR || stream.parameters.videoRange != "PQ" else {
            self = .refuse(.hdrVideo(range: stream.parameters.videoRange))
            return
        }
        self = .copy(codec: codec)
    }

    /// Whether the device decodes a video codec string the bridge delivers. AV1 and 10-bit
    /// H.264 (profile 110, `6e`) have a decoder on some devices only.
    private static func decodes(_ codec: String, on support: AVPlayerSupport) -> Bool {
        if codec.hasPrefix("av01") { return support.videoCodecs.contains(.av1) }
        if codec.hasPrefix("avc1.6e") { return support.decodesH264High10 }
        return true
    }
}

/// What the bridge does with one audio stream, decided from what the stream says of itself and
/// from the packets of it the file opens with.
enum AudioDecision {
    case copy(CopiedAudio)
    /// Left out of the playlists. `name` is the codec as the player's details show it.
    case omit(name: String)

    /// An audio stream delivered byte for byte.
    struct CopiedAudio {
        let stream: DemuxedStream
        /// The RFC 6381 string a playlist's `CODECS` carries.
        let codec: String
        /// Nanoseconds: the earliest of the stream's packets the file opens with.
        let start: Int64
        /// Zero when the codec's frames have no fixed length.
        let samplesPerFrame: Int

        /// Nil for a codec the bridge does not deliver, and for a stream the opening holds less
        /// than one MP4 sample of, which has no init segment.
        init?(_ stream: DemuxedStream, openingWith packets: [DemuxedPacket]) {
            guard let codec = stream.parameters.playlistCodec,
                  let start = packets.compactMap(\.presentationTime).min()
            else { return nil }
            let frame = stream.parameters.samplesPerFrame(readingHeaderOf: packets[0].data)
            guard packets.count >= stream.parameters.framesPerSample(of: frame) else { return nil }
            self.stream = stream
            self.codec = codec
            self.start = start
            samplesPerFrame = frame
        }

        func rendition(origin: Int64) -> Rendition {
            Rendition(
                stream: stream, codec: codec, supplementalCodec: nil,
                clock: MediaClock(
                    timescale: Int64(stream.parameters.sampleRate), origin: origin,
                    grid: samplesPerFrame > 0
                        ? .init(
                            anchor: start, step: Int64(samplesPerFrame), tolerance: gridTolerance,
                            framesPerSample: Int64(stream.parameters.framesPerSample(of: samplesPerFrame)))
                        : nil),
                decodeLead: 0)
        }

        /// Nanoseconds. A container whose tick is no longer than a sample stores each frame's
        /// time to within a tick or two, so a frame a quarter of a frame off the grid is off it
        /// in the source: a recording joined from parts goes on part of a frame late after each
        /// join, and at half a frame two frames would be put in one slot. A coarser time was
        /// rounded, each frame of a lace by an error of its own, and goes back on the grid
        /// wherever it is.
        private var gridTolerance: Int64 {
            let sampleRate = Int64(stream.parameters.sampleRate)
            return stream.tick * sampleRate <= 1_000_000_000
                ? Int64(samplesPerFrame) * 250_000_000 / sampleRate : .max
        }
    }

    /// `packets` are the stream's own, of those the file opens with.
    init(for stream: DemuxedStream, openingWith packets: [DemuxedPacket]) {
        self = CopiedAudio(stream, openingWith: packets).map(Self.copy) ?? .omit(name: stream.parameters.displayName)
    }

    var copied: CopiedAudio? {
        switch self {
        case .copy(let audio): audio
        case .omit: nil
        }
    }

    var omitted: String? {
        switch self {
        case .copy: nil
        case .omit(let name): name
        }
    }
}

/// Where a keyframe list cuts a file into segments.
struct SegmentCuts {
    /// Each segment's run of keyframes, up to the next segment's first.
    let spans: [Range<Int>]
    /// Nanoseconds in the file's own time: where each segment starts, then where the file ends.
    let boundaries: [Int64]
    /// How much of the file each segment's keyframes span.
    let bytes: [Int64]

    /// `end` gives the time the file ends, from the time its last segment starts. `keyframes`
    /// holds two or more. Throws
    /// `BridgeRefusal.indexGap` when more of the file follows the last keyframe than
    /// `indexGapLimit`.
    init(
        at keyframes: [IndexedKeyframe], fileSize: Int64, indexGapLimit: Duration,
        end: (_ lastSegmentStart: Int64) -> Int64
    ) throws {
        let starts = keyframes.indices.reduce(into: [Int]()) { starts, index in
            if let last = starts.last, keyframes[index].time - keyframes[last].time < BridgePlan.targetSegmentLength {
                return
            }
            starts.append(index)
        }
        spans = zip(starts, starts.dropFirst() + [keyframes.count]).map { $0..<$1 }
        bytes = spans.map { span in
            (span.upperBound < keyframes.count ? keyframes[span.upperBound].position : fileSize)
                - keyframes[span.lowerBound].position
        }
        let fileEnd = end(keyframes[spans[spans.count - 1].lowerBound].time)
        let lastEntry = keyframes[keyframes.count - 1].time
        if Duration.nanoseconds(fileEnd - lastEntry) > indexGapLimit {
            throw BridgeRefusal.indexGap(after: Int((lastEntry - keyframes[0].time) / 1_000_000_000))
        }
        boundaries = spans.map { keyframes[$0.lowerBound].time } + [fileEnd]
    }

    /// Every segment, timed on the video's `clock`.
    func segments(on clock: MediaClock) -> [BridgePlan.Segment] {
        spans.indices.map { index in
            BridgePlan.Segment(
                entries: spans[index],
                seconds: clock.seconds(at: boundaries[index + 1]) - clock.seconds(at: boundaries[index]),
                end: boundaries[index + 1])
        }
    }

    /// One segment that starts where segment `index` does and lasts to the end of the file.
    func segment(from index: Int, on clock: MediaClock) -> BridgePlan.Segment {
        let end = boundaries[boundaries.count - 1]
        return BridgePlan.Segment(
            entries: spans[index], seconds: clock.seconds(at: end) - clock.seconds(at: boundaries[index]), end: end)
    }
}

/// How the video's frames are spaced, which fixes how far decode times run ahead.
struct VideoPacing {
    /// Nil when the container declares no frame rate, or one that is not a whole number of ticks.
    let grid: MediaClock.Grid?
    /// Ticks of `BridgePlan.videoTimescale`.
    let decodeLead: Int64

    /// Nanoseconds. A transport stream copied from a Matroska file keeps the millisecond its
    /// times were rounded to, under a tick of its own ninety times finer. Left off the grid,
    /// such a picture is shown before the decode time its rank gives it, and AVPlayer never
    /// starts the item.
    private static let coarsestRounding: Int64 = 1_000_000

    init(of stream: DemuxedStream, startingAt start: Int64, firstPacket: DemuxedPacket?) {
        grid = stream.frameRate.flatMap { rate -> MediaClock.Grid? in
            let (step, remainder) = (BridgePlan.videoTimescale * rate.denominator)
                .quotientAndRemainder(dividingBy: rate.numerator)
            return remainder == 0
                ? .init(anchor: start, step: step, tolerance: max(stream.tick, Self.coarsestRounding)) : nil
        }
        let frameTicks = grid?.step
            ?? firstPacket?.duration.map { $0 * BridgePlan.videoTimescale / 1_000_000_000 }
            ?? 0
        decodeLead = Int64(stream.parameters.reorderDepth) * frameTicks
    }
}
