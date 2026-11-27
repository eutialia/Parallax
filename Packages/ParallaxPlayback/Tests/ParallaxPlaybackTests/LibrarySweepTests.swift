import AetherLibavcodec
import AetherLibavformat
import AetherLibavutil
import CryptoKit
import Foundation
import ParallaxCore
import Synchronization
import Testing
import ParallaxPlayback

/// Plays a real library through `MediaDelivery`, as the app plays a file from a share, and
/// reports, in aggregates only, what the bridge makes of it.
///
/// `PARALLAX_SWEEP_ROOT` is a mounted share or folder. `PARALLAX_SWEEP_LIMIT` caps the sample,
/// 80 by default: one MKV from each folder, folders in path order. Each file either has every
/// sampled segment, and the one after it, match its source or is refused with a named reason. No
/// file or folder name is printed: a library's names are private.
@Suite("Library sweep")
struct LibrarySweepTests {
    private static let root = ProcessInfo.processInfo.environment["PARALLAX_SWEEP_ROOT"]
    private static let limit = max(0, ProcessInfo.processInfo.environment["PARALLAX_SWEEP_LIMIT"].flatMap(Int.init) ?? 80)

    @Test(
        "every sampled MKV either has segments that match its source or a named refusal",
        .enabled(if: root != nil), .timeLimit(.minutes(60)))
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
            results.append(await FileResult.sweeping(url, place: place))
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
        /// A segment the delivery served differs from the source: which one, and how.
        case mismatch(String)
        /// Anything else the delivery threw: the error, or its type.
        case failed(String)
    }

    let place: Int
    var outcome = Outcome.matches
    /// Read before the delivery's URL was handed out: the format's first look, the headers, the
    /// keyframe list and the plan's opening.
    var openBytes = 0
    var deliveredAudio: [String] = []
    /// The source's audio streams the master playlist does not offer.
    var omittedAudio = 0
    /// Seconds by which a sample's time strays from where the video's first segment puts the
    /// file's timeline, worst per codec.
    var timingStray: [String: Double] = [:]
    /// The most bytes one served segment came to, by "video" and "audio".
    var largestBuilt: [String: Int] = [:]

    static func sweeping(_ url: URL, place: Int) async -> FileResult {
        var result = FileResult(place: place)
        do {
            let reader = try CountingFileReader(url)
            let file = try await DeliveredFile.start(reading: reader, named: url.lastPathComponent)
            result.openBytes = reader.bytesRead
            do {
                try await result.compare(file, with: SourceFile(url))
                await file.stop()
            } catch {
                await file.stop()
                throw error
            }
        } catch Unplayable.refused(let refusal) {
            result.outcome = .refused(refusal)
        } catch let reason as Unplayable {
            result.outcome = .failed("unplayable: \(reason)")
        } catch {
            result.outcome = .failed(String(describing: type(of: error)))
        }
        return result
    }

    /// The places of a track sampled, each fetched with the segment after it: the first, the
    /// middle, the last, and the one after the longest. The last is where an audio track that
    /// ends early takes all its audio left. The one after the longest starts its audio read
    /// furthest back.
    private static func places(in seconds: [Double]) -> [(index: Int, name: String)] {
        let last = seconds.count - 1
        let longest = seconds.indices.max { seconds[$0] < seconds[$1] } ?? 0
        let places = [(0, "first"), (seconds.count / 2, "middle"), (last, "last"), (min(longest + 1, last), "after the longest")]
        return Dictionary(places, uniquingKeysWith: { first, _ in first }).sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
    }

    private mutating func compare(_ file: DeliveredFile, with source: SourceFile) async throws {
        let master = try await file.master
        let audio = master.split(separator: "\n").filter { $0.contains("TYPE=AUDIO") }
        let renditions = ["v"] + audio.indices.map { "a\($0)" }
        omittedAudio = source.audioStreams - audio.count

        let videoInit = try await file.bytes("v-init.mp4")
        let video = try await file.segmentSeconds(of: "v.m3u8")
        var videoStarts: [Int: Double] = [:]
        func videoStart(_ index: Int) async throws -> Double? {
            if let start = videoStarts[index] { return start }
            guard video.indices.contains(index) else { return nil }
            let segment = try await file.bytes("v-\(index).m4s")
            let first = try readBackSamples(of: videoInit + segment, pathExtension: "mp4").first
            videoStarts[index] = first.map { Double($0.presentation) / Double($0.timescale) }
            return videoStarts[index]
        }
        // A file's times may start hours in, so its opening is counted in pictures.
        let sourceOpening = try source.packets(from: 0, to: .infinity, videoPackets: 600)
        // The delivery's time less the source's, for the first sample of a copied track: the
        // video's, or where the video is converted, the first audio's. Every sample of every
        // track keeps it: that is one timeline, with nothing drifting.
        let opening = try readBackSamples(of: videoInit + (try await file.bytes("v-0.m4s")), pathExtension: "mp4")
        var timeline = opening.first.flatMap { first in
            sourceOpening.first { $0.md5 == first.md5 }.map { Double(first.presentation) / Double(first.timescale) - ($0.seconds ?? 0) }
        }

        var found: String?
        for (place, rendition) in renditions.enumerated() {
            let initSegment = try await file.bytes("\(rendition)-init.mp4")
            let codec = try SourceFile.codec(ofInitSegment: initSegment)
            let seconds = try await file.segmentSeconds(of: "\(rendition).m3u8")
            let kind = rendition == "v" ? "video" : "audio"
            var copied: Bool?
            for (index, placeName) in Self.places(in: seconds) {
                let name = "\(kind) \(codec) segment \(placeName)"
                var samples: [ReadbackSample] = []
                for fetched in [index, index + 1] where seconds.indices.contains(fetched) {
                    let bytes = try await file.bytes("\(rendition)-\(fetched).m4s")
                    largestBuilt[kind] = max(largestBuilt[kind] ?? 0, bytes.count)
                    samples += try readBackSamples(of: initSegment + bytes, pathExtension: "mp4")
                }
                guard let head = samples.first, let tail = samples.last else {
                    found = found ?? "\(name): empty"
                    continue
                }
                let headSeconds = Double(head.presentation) / Double(head.timescale)
                let tailSeconds = Double(tail.presentation) / Double(tail.timescale)
                let window = try timeline.map { try source.packets(from: headSeconds - $0 - 30, to: tailSeconds - $0 + 10) }
                    ?? sourceOpening
                let starts = window.indices.filter { window[$0].md5 == head.md5 }
                if copied == nil { copied = !starts.isEmpty }
                guard copied == true else {
                    // A converted segment holds none of the source's packets. It starts on the
                    // tick the video's segment does.
                    if index > 0, let shown = try await videoStart(index), abs(headSeconds - shown) > 0.001 {
                        found = found ?? "\(name): starts off its boundary"
                    }
                    continue
                }
                guard !starts.isEmpty else {
                    found = found ?? "\(name): first sample not in the source"
                    continue
                }
                // Silence and still pictures repeat their packets, so the run is the one that
                // matches whole nearest the time the timeline puts it at.
                let runs = starts.map { start in
                    Array(window[start...].lazy.filter { $0.stream == window[start].stream }.prefix(samples.count))
                }.filter { $0.map(\.md5) == samples.map(\.md5) }
                let distance = { (run: [SourceFile.Packet]) in
                    timeline.map { abs((run[0].seconds ?? .infinity) - (headSeconds - $0)) } ?? 0
                }
                guard let run = runs.min(by: { distance($0) < distance($1) }) else {
                    found = found ?? "\(name): \(samples.count) samples are not a run of the source's"
                    continue
                }
                let offset = timeline ?? headSeconds - (run[0].seconds ?? 0)
                timeline = offset
                if rendition == "v", run.map(\.isKeyframe) != samples.map(\.isKeyframe) {
                    found = found ?? "\(name): keyframe flags"
                }
                if rendition == "v", !head.isKeyframe { found = found ?? "\(name): starts on no keyframe" }
                // An audio segment starts with the frame heard as its video segment's first
                // picture shows. An MP4 sample may join two frames.
                if rendition != "v", index > 0, let shown = try await videoStart(index), samples.count > 1 {
                    let frame = Double(samples[1].presentation - head.presentation) / Double(head.timescale)
                    if headSeconds < shown - 0.001 || headSeconds >= shown + 2 * frame + 0.001 {
                        found = found ?? String(format: "%@: starts %.1f ms from its video", name, (headSeconds - shown) * 1000)
                    }
                }
                let stray = zip(samples, run).compactMap { served, source in
                    source.seconds.map { abs(Double(served.presentation) / Double(served.timescale) - $0 - offset) }
                }.max() ?? 0
                let strayName = rendition == "v" ? "video \(codec)" : codec
                timingStray[strayName] = max(timingStray[strayName] ?? 0, stray)
                // Half a frame at 60 fps. A sample in the wrong slot strays by a whole one.
                if stray > 0.008 { found = found ?? String(format: "%@: a sample strays %.1f ms", name, stray * 1000) }
            }
            if place > 0 {
                let channels = SweepReport.attribute("CHANNELS", of: audio[place - 1]) ?? ""
                deliveredAudio.append(codec + (copied == false ? " converted" : "") + (channels.hasSuffix("JOC") ? " \(channels)" : ""))
            }
        }
        outcome = found.map(Outcome.mismatch) ?? .matches
    }
}

/// The source file as libavformat reads it on a context of its own: the file's path, a seek by
/// time, none of the bridge's reading.
private struct SourceFile {
    struct Packet {
        let stream: Int
        let md5: String
        let isKeyframe: Bool
        let seconds: Double?
    }

    let url: URL
    let audioStreams: Int

    init(_ url: URL) throws {
        self.url = url
        audioStreams = try Self.opened(url) { context in
            (0..<Int(context.pointee.nb_streams)).count {
                context.pointee.streams[$0]?.pointee.codecpar.pointee.codec_type == AVMEDIA_TYPE_AUDIO
            }
        }
    }

    private static func opened<Value>(_ url: URL, _ body: (UnsafeMutablePointer<AVFormatContext>) throws -> Value) throws -> Value {
        var context: UnsafeMutablePointer<AVFormatContext>?
        let opened = avformat_open_input(&context, url.path, nil, nil)
        guard opened >= 0, let context else { throw ReadbackFailure(code: opened) }
        defer {
            var context: UnsafeMutablePointer<AVFormatContext>? = context
            avformat_close_input(&context)
        }
        return try body(context)
    }

    /// The codec of an init segment's one track, as libavformat names it: "aac", "flac".
    static func codec(ofInitSegment bytes: Data) throws -> String {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("mp4")
        try bytes.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        return try opened(url) { context in
            guard let parameters = context.pointee.streams[0]?.pointee.codecpar else { throw ReadbackFailure(code: -22) }
            return String(cString: avcodec_get_name(parameters.pointee.codec_id))
        }
    }

    /// Every packet of every stream from the keyframe a seek to `lower` seconds lands on, in file
    /// order, until the video reaches `upper` or has given `videoPackets`.
    func packets(from lower: Double, to upper: Double, videoPackets: Int = .max) throws -> [Packet] {
        let sought = try packets(seekingTo: lower > 0 ? lower : nil, to: upper, videoPackets: videoPackets)
        // A seek to before the file's first time lands on its first keyframe's cue, past the
        // audio stored ahead of it, so such a window is read from the file's start.
        guard let first = sought.first?.seconds, first > lower else { return sought }
        return try packets(seekingTo: nil, to: upper, videoPackets: videoPackets)
    }

    private func packets(seekingTo lower: Double?, to upper: Double, videoPackets: Int) throws -> [Packet] {
        try Self.opened(url) { context in
            if let lower {
                let status = av_seek_frame(context, -1, Int64(lower * 1_000_000), AVSEEK_FLAG_BACKWARD)
                guard status >= 0 else { throw ReadbackFailure(code: status) }
            }
            var packet = av_packet_alloc()
            defer { av_packet_free(&packet) }
            guard let packet else { throw ReadbackFailure(code: -12) }
            var collected: [Packet] = []
            var pictures = 0
            while pictures < videoPackets, av_read_frame(context, packet) >= 0 {
                defer { av_packet_unref(packet) }
                guard let stream = context.pointee.streams[Int(packet.pointee.stream_index)]?.pointee,
                      let data = packet.pointee.data
                else { continue }
                let seconds = packet.pointee.pts == Int64.min ? nil
                    : Double(packet.pointee.pts) * Double(stream.time_base.num) / Double(stream.time_base.den)
                if stream.codecpar.pointee.codec_type == AVMEDIA_TYPE_VIDEO {
                    if let seconds, seconds > upper { break }
                    pictures += 1
                }
                collected.append(Packet(
                    stream: Int(packet.pointee.stream_index),
                    md5: Insecure.MD5.hash(data: Data(bytes: data, count: Int(packet.pointee.size)))
                        .map { String(format: "%02x", $0) }.joined(),
                    isKeyframe: packet.pointee.flags & AV_PKT_FLAG_KEY != 0, seconds: seconds))
            }
            return collected
        }
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

    static func attribute(_ name: String, of line: Substring) -> String? {
        guard let start = line.range(of: "\(name)=\"")?.upperBound else { return nil }
        return String(line[start...].prefix { $0 != "\"" })
    }

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
            "SWEEP audio tracks left out per delivered file: \(tally(delivered.map { "\($0.omittedAudio)" }))",
            "SWEEP worst timing stray: " + stray.sorted { $0.key < $1.key }
                .map { String(format: "%@ %.2f ms", $0.key, $0.value * 1000) }.joined(separator: ", "),
            "SWEEP read to open: \(spread(results.map(\.openBytes)))",
            "SWEEP largest segment served: " + ["video", "audio"].map { kind in
                "\(kind) \((results.compactMap { $0.largestBuilt[kind] }.max() ?? 0) >> 20) MB"
            }.joined(separator: ", "),
        ] + unexplained.map { "SWEEP unexplained \($0)" }
    }
}
