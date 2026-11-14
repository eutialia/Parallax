import AetherLibavcodec
import AetherLibavformat
import AetherLibavutil
import CryptoKit
import Foundation
import ParallaxCore
import ParallaxTestScaling
import Synchronization
import Testing
@testable import ParallaxPlayback

/// Runs the bridge over a real library and reports, in aggregates only, what it makes of it.
///
/// `PARALLAX_SWEEP_ROOT` is a mounted share or folder. `PARALLAX_SWEEP_LIMIT` caps the sample,
/// 80 by default: one MKV from each folder, folders in path order. Each file either has every
/// sampled segment match its source or is refused with a named reason. No file or folder name
/// is printed: a library's names are private.
@Suite("Library sweep")
struct LibrarySweepTests {
    private static let root = ProcessInfo.processInfo.environment["PARALLAX_SWEEP_ROOT"]
    private static let limit = max(0, ProcessInfo.processInfo.environment["PARALLAX_SWEEP_LIMIT"].flatMap(Int.init) ?? 80)

    @Test(
        "every sampled MKV either has segments that match its source or a named refusal",
        .enabled(if: root != nil), .scaledTimeLimit(minutes: 60))
    func librarySweep() async throws {
        // libavformat logs to stderr, and a log line may one day carry the path it opened.
        av_log_set_level(AV_LOG_QUIET)
        let all = Self.mkvs(under: URL(fileURLWithPath: try #require(Self.root)))
        let sample = Dictionary(grouping: all) { $0.deletingLastPathComponent().path }
            .sorted { $0.key < $1.key }.compactMap { $0.value.min { $0.path < $1.path } }
            .prefix(Self.limit)
        // An unmounted share is an empty folder, and an empty sample would pass.
        try #require(!sample.isEmpty)

        var results: [FileResult] = []
        for (place, url) in sample.enumerated() {
            results.append(await FileResult(sweeping: url, place: place))
        }
        let report = SweepReport(results, of: all.count)
        print(report.lines.joined(separator: "\n"))
        #expect(report.unexplained.isEmpty, "\(report.unexplained)")
    }

    private static func mkvs(under root: URL) -> [URL] {
        let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        return (walker?.allObjects ?? []).compactMap { $0 as? URL }
            .filter { $0.pathExtension.lowercased() == "mkv" && !$0.lastPathComponent.hasPrefix(".") }
    }
}

/// What one file came to. `place` is the file's position in the sample, the only way a report
/// points at a file.
private struct FileResult {
    enum Outcome {
        case matches
        case refused(BridgeRefusal)
        /// A segment the bridge built differs from the source: which one, and how.
        case mismatch(String)
        /// Anything else the bridge threw: the error's type.
        case failed(String)
    }

    let place: Int
    let outcome: Outcome
    /// Read before the plan: opening the container and describing its streams, then the index.
    var openBytes = 0
    var indexBytes = 0
    /// The first segment and the search for where each audio track ends.
    var planBytes = 0
    var deliveredAudio: [String] = []
    var omittedAudio: [String] = []
    /// Seconds by which a sample's time strays from where the video's first segment puts the
    /// file's timeline, worst per codec.
    var timingStray: [String: Double] = [:]
    /// The most bytes one built segment came to, by "video" and "audio".
    var largestBuilt: [String: Int] = [:]

    init(sweeping url: URL, place: Int) async {
        self.place = place
        do {
            // A pass of its own measures the stages, so the outcome comes from the app's entry point.
            let stages = try CountingFileReader(url)
            let whole = try? await MediaDemuxer.open(stages)
            if let whole {
                openBytes = stages.bytesRead
                _ = try? await whole.keyframes()
                indexBytes = stages.bytesRead - openBytes
            }
            let reader = try CountingFileReader(url)
            let session = try await BridgeSession.open(reader, support: BridgeFixture.everyDecoder, showsHDR: true)
            planBytes = reader.bytesRead - openBytes - indexBytes
            let plan = session.plan
            let keyframes = session.keyframes
            deliveredAudio = plan.audio.map { track in
                let channels = track.rendition.stream.parameters.playlistChannels
                return track.rendition.codec + (channels.hasSuffix("JOC") ? " \(channels)" : "")
            }
            omittedAudio = plan.omittedAudio

            let tracks = [(RenditionID.video, plan.video)] + plan.audio.indices.map { (RenditionID.audio($0), plan.audio[$0]) }
            var found: String?
            // The plan describes each track from the file's opening alone. Described from the
            // whole first span instead, it must come out the same.
            if let whole {
                // A track of a codec the bridge delivers is left out only when the opening read
                // saw no packet of it.
                let deliverable = whole.streams.count { $0.kind == .audio && $0.parameters.playlistCodec != nil }
                if plan.audio.count < deliverable {
                    found = "\(deliverable - plan.audio.count) deliverable audio tracks left out"
                }
                let first = plan.video.segments[0].entries
                let packets = try await whole.packets(from: first.lowerBound, to: first.upperBound)
                for (_, track) in tracks {
                    let described = packets.filter { $0.stream == track.rendition.stream.index }
                    if try SegmentWriter.initSegment(for: track.rendition, describedBy: described) != track.initSegment {
                        found = found ?? "\(track.rendition.codec) init segment: not the first span's"
                    }
                }
            }
            let fileSize = Int64(try await reader.fileSize)
            let fileBytes = { (segment: BridgePlan.Segment) in
                (segment.entries.upperBound < keyframes.count ? keyframes[segment.entries.upperBound].position : fileSize)
                    - keyframes[segment.entries.lowerBound].position
            }
            // The bridge's time less the source's, for the video's first sample. Every sample of
            // every track keeps it: that is one timeline, with nothing drifting.
            var timeline: Double?
            for (id, track) in tracks {
                // The last segment is where an audio track that ends early takes all its audio
                // left. The one after the longest span starts its audio read furthest back.
                let segments = track.segments
                let last = segments.count - 1
                let largest = segments.indices.max { fileBytes(segments[$0]) < fileBytes(segments[$1]) } ?? 0
                let longest = segments.indices.max { segments[$0].seconds < segments[$1].seconds } ?? 0
                let places = [
                    (0, "first"), (segments.count / 2, "middle"), (last, "last"), (largest, "largest"),
                    (min(longest + 1, last), "after the longest"),
                ]
                let initSegment = try await Self.bytes(session, BridgeResource.initSegment(id).path)
                for (index, place) in Dictionary(places, uniquingKeysWith: { first, _ in first }).sorted(by: { $0.key < $1.key }) {
                    let segment = segments[index]
                    let (readBack, built) = try await Self.samples(of: session, BridgeResource.mediaSegment(id, index).path, after: initSegment)
                    let kind = id == .video ? "video" : "audio"
                    largestBuilt[kind] = max(largestBuilt[kind] ?? 0, built)
                    let source = try SourcePackets(
                        of: url, stream: track.rendition.stream.index, videoStream: plan.video.rendition.stream.index,
                        clock: track.rendition.clock,
                        from: index == 0 ? nil : keyframes[segment.entries.lowerBound].time,
                        to: segment.entries.upperBound == keyframes.count || index == track.segments.count - 1 && id != .video
                            ? nil : keyframes[segment.entries.upperBound].time,
                        readingUntil: segment.entries.upperBound == keyframes.count
                            ? nil : keyframes[segment.entries.upperBound].time)
                    let name = "\(kind) \(track.rendition.codec) segment \(place)"
                    guard readBack.map(\.md5) == source.packets.map(\.md5) else {
                        found = found ?? "\(name): \(readBack.count) samples for \(source.packets.count)"
                        continue
                    }
                    if id == .video, readBack.map(\.isKeyframe) != source.packets.map(\.isKeyframe) {
                        found = found ?? "\(name): keyframe flags"
                    }
                    let offsets = zip(readBack, source.packets).compactMap { built, source in
                        source.seconds.map { Double(built.presentation) / Double(built.timescale) - $0 }
                    }
                    timeline = timeline ?? offsets.first
                    let stray = offsets.map { abs($0 - (timeline ?? 0)) }.max() ?? 0
                    let codec = id == .video ? "video \(track.rendition.codec.prefix(4))" : track.rendition.codec
                    timingStray[codec] = max(timingStray[codec] ?? 0, stray)
                    // Half a frame at 60 fps. A sample in the wrong slot strays by a whole one.
                    if stray > 0.008 { found = found ?? String(format: "%@: a sample strays %.1f ms", name, stray * 1000) }
                }
            }
            outcome = found.map(Outcome.mismatch) ?? .matches
        } catch let refusal as BridgeRefusal {
            outcome = .refused(refusal)
        } catch {
            outcome = .failed(String(describing: type(of: error)))
        }
    }

    private static func bytes(_ session: BridgeSession, _ path: String) async throws -> Data {
        try await #require(try await session.resource(at: path)).bytes()
    }

    /// A segment's samples, read back a fragment at a time behind its init segment, so no
    /// segment is held whole: the largest run to 50 MB. With the bytes it came to.
    private static func samples(
        of session: BridgeSession, _ path: String, after initSegment: Data
    ) async throws -> (samples: [ReadbackSample], bytes: Int) {
        guard case .streamed(let produce) = try #require(try await session.resource(at: path)).body else {
            throw ReadbackFailure(code: -22)
        }
        let producer = produce()
        defer { producer.cancel() }
        var samples: [ReadbackSample] = []
        var bytes = 0
        while let fragment = try await producer.next() {
            bytes += fragment.count
            samples += try readBackSamples(of: initSegment + fragment, pathExtension: "mp4")
        }
        return (samples, bytes)
    }
}

/// The packets of one stream of a segment, read by libavformat on a context of its own: the
/// file's path, a seek by time, none of the bridge's reading.
///
/// The membership rules are the bridge's contract, restated here on purpose. Video belongs to a
/// segment by position: from its first keyframe up to the next segment's. Audio belongs by
/// time, and a stream takes nothing more once a packet of it reaches the segment's end.
private struct SourcePackets {
    struct Packet {
        let md5: String
        let isKeyframe: Bool
        let seconds: Double?
    }

    let packets: [Packet]

    /// `lower` nil takes the audio timed before the first keyframe too, `upper` nil everything
    /// after. The read stops once the video is ten seconds past `readingUntil`: muxers store
    /// audio within a cluster, five seconds at most, of the video it plays with. The bridge
    /// gives up 4 MB past it, so audio stored further on shows here as a mismatch.
    ///
    /// Audio frames an MP4 sample joins, by `clock`, are timed by the sample's start, and an
    /// unfinished last sample is left out.
    init(
        of url: URL, stream: Int, videoStream: Int, clock: MediaClock, from lower: Int64?, to upper: Int64?,
        readingUntil end: Int64?
    ) throws {
        var context: UnsafeMutablePointer<AVFormatContext>?
        let opened = avformat_open_input(&context, url.path, nil, nil)
        guard opened >= 0, let context else { throw ReadbackFailure(code: opened) }
        defer {
            var context: UnsafeMutablePointer<AVFormatContext>? = context
            avformat_close_input(&context)
        }
        if let lower {
            // Microseconds, thirty seconds early: audio stored ahead of its keyframe is read too.
            let status = av_seek_frame(context, -1, max(0, lower / 1000 - 30_000_000), AVSEEK_FLAG_BACKWARD)
            guard status >= 0 else { throw ReadbackFailure(code: status) }
        }
        var packet = av_packet_alloc()
        defer { av_packet_free(&packet) }
        guard let packet else { throw ReadbackFailure(code: -12) }

        func nanoseconds(_ value: Int64, _ index: Int32) -> Int64? {
            guard value != Int64.min, let base = context.pointee.streams[Int(index)]?.pointee.time_base else { return nil }
            return av_rescale_q(value, base, AVRational(num: 1, den: 1_000_000_000))
        }
        let (lowerTime, upperTime) = (lower ?? .min, upper ?? .max)
        var collected: [Packet] = []
        var sampleStarts: [Int64?] = []
        var videoStarted = false
        var videoEnded = false
        var audioEnded = false
        var audioBelongs = false
        while av_read_frame(context, packet) >= 0 {
            defer { av_packet_unref(packet) }
            let index = Int(packet.pointee.stream_index)
            let time = nanoseconds(packet.pointee.pts, packet.pointee.stream_index)
            let isKeyframe = packet.pointee.flags & AV_PKT_FLAG_KEY != 0
            if index == videoStream, isKeyframe, let time {
                if let end, time >= end + 10_000_000_000 { break }
                if time >= upperTime { videoEnded = true } else if time >= lowerTime { videoStarted = true }
            }
            guard index == stream, let data = packet.pointee.data else { continue }
            let belongs: Bool
            if stream == videoStream {
                belongs = videoStarted && !videoEnded
            } else {
                // A frame with no time of its own follows the one before it in its lace.
                if let time = time.map(clock.sampleStart(at:)), !audioEnded {
                    audioEnded = time >= upperTime
                    audioBelongs = time >= lowerTime && time < upperTime
                }
                belongs = !audioEnded && audioBelongs
            }
            if belongs {
                collected.append(Packet(
                    md5: Insecure.MD5.hash(data: Data(bytes: data, count: Int(packet.pointee.size)))
                        .map { String(format: "%02x", $0) }.joined(),
                    isKeyframe: isKeyframe, seconds: time.map { Double($0) / 1e9 }))
                sampleStarts.append(time.map(clock.sampleStart(at:)) ?? sampleStarts.last ?? nil)
            }
        }
        let framesPerSample = Int(clock.grid?.framesPerSample ?? 1)
        let lastSample = sampleStarts.reversed().prefix { $0 == sampleStarts.last }.count
        let unfinished = upper == nil && stream != videoStream && lastSample < framesPerSample ? lastSample : 0
        packets = Array(collected.dropLast(unfinished))
    }
}

/// A file on a mounted volume, counting what it hands out.
private final class CountingFileReader: RandomAccessReading {
    private let descriptor: Int32
    private let size: UInt64
    private let counted = Mutex(0)
    var bytesRead: Int { counted.withLock { $0 } }

    init(_ url: URL) throws {
        descriptor = open(url.path, O_RDONLY)
        guard descriptor >= 0 else { throw CocoaError(.fileReadNoSuchFile) }
        var status = stat()
        fstat(descriptor, &status)
        size = UInt64(status.st_size)
    }

    deinit { close(descriptor) }

    var fileSize: UInt64 { get async throws { size } }

    func read(offset: UInt64, length: Int) async throws -> Data {
        var data = Data(count: length)
        let read = data.withUnsafeMutableBytes { pread(descriptor, $0.baseAddress, length, off_t(offset)) }
        guard read >= 0 else { throw POSIXError(.EIO) }
        counted.withLock { $0 += read }
        return data.prefix(read)
    }
}

private struct SweepReport {
    let lines: [String]
    /// Files that neither matched nor were refused with a reason. Unreadable is no reason here.
    let unexplained: [String]

    init(_ results: [FileResult], of libraryCount: Int) {
        func tally(_ names: [String]) -> String {
            Dictionary(names.map { ($0, 1) }, uniquingKeysWith: +).sorted { ($1.value, $0.key) < ($0.value, $1.key) }
                .map { "\($0.key) \($0.value)" }.joined(separator: ", ")
        }
        func spread(_ values: [Int]) -> String {
            let sorted = values.sorted()
            guard !sorted.isEmpty else { return "none" }
            return "median \(sorted[sorted.count / 2] >> 10) KB, 90th \(sorted[sorted.count * 9 / 10] >> 10) KB, worst \(sorted[sorted.count - 1] >> 10) KB"
        }
        let outcomes = results.map { result -> String in
            switch result.outcome {
            case .matches: "matches"
            case .refused(.indexGap): "refused: index stops"
            case .refused(let refusal): "refused: \(refusal)"
            case .mismatch: "mismatch"
            case .failed(let error): "failed: \(error)"
            }
        }
        unexplained = results.compactMap { result in
            switch result.outcome {
            // A file the bridge calls unreadable may be damaged, or the bridge may be wrong about
            // it. Someone has to look.
            case .refused(.unreadable(let detail)): "file \(result.place): unreadable: \(detail)"
            case .matches, .refused: nil
            case .mismatch(let detail): "file \(result.place): \(detail)"
            case .failed(let error): "file \(result.place): \(error)"
            }
        }
        let delivered = results.filter { if case .matches = $0.outcome { true } else { false } }
        let stray = results.flatMap(\.timingStray).reduce(into: [String: Double]()) { $0[$1.key] = max($0[$1.key] ?? 0, $1.value) }
        lines = [
            "SWEEP \(results.count) files of \(libraryCount), one per folder",
            "SWEEP outcomes: \(tally(outcomes))",
            "SWEEP audio tracks per delivered file: \(tally(delivered.map { "\($0.deliveredAudio.count)" }))",
            "SWEEP audio delivered: \(tally(delivered.flatMap(\.deliveredAudio)))",
            "SWEEP audio left out: \(tally(delivered.flatMap(\.omittedAudio)))",
            "SWEEP worst timing stray: " + stray.sorted { $0.key < $1.key }
                .map { String(format: "%@ %.2f ms", $0.key, $0.value * 1000) }.joined(separator: ", "),
            "SWEEP read to open: \(spread(results.map(\.openBytes)))",
            "SWEEP read for the index: \(spread(results.map(\.indexBytes)))",
            "SWEEP read for the plan: \(spread(delivered.map(\.planBytes)))",
            "SWEEP largest segment built: " + ["video", "audio"].map { kind in
                "\(kind) \((results.compactMap { $0.largestBuilt[kind] }.max() ?? 0) >> 20) MB"
            }.joined(separator: ", "),
        ] + unexplained.map { "SWEEP unexplained \($0)" }
    }
}
