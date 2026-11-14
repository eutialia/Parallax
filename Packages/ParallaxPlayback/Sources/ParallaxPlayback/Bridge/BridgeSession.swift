import Foundation
import ParallaxCore
import Synchronization

/// Serves one bridged file: playlists from the plan, and each segment built from the file when
/// it is asked for. It keeps no segment between requests, so the same path always gives the
/// same bytes, in whatever order AVPlayer asks.
struct BridgeSession: MediaResponder {
    let plan: BridgePlan
    /// The video stream's index, which every segment's read starts from.
    let keyframes: [IndexedKeyframe]
    let reads = SegmentReads()
    let memory = BridgeMemory()
    private let cache: SessionBlockCache
    private let demuxers: DemuxerPool
    private let fragmentLimits: FragmentLimits

    /// Reads the file's headers, index and opening. Throws a `BridgeRefusal` for a file the
    /// bridge cannot deliver, and the reader's own error when a read fails.
    static func open(
        _ reader: any RandomAccessReading, support: AVPlayerSupport, showsHDR: Bool,
        blockSize: Int = SessionBlockCache.defaultBlockSize, bytesKept: Int = SessionBlockCache.defaultBytesKept,
        fragmentLimits: FragmentLimits = .standard
    ) async throws -> BridgeSession {
        do {
            let cache = SessionBlockCache(
                reader: reader, size: try await reader.fileSize, blockSize: blockSize, bytesKept: bytesKept)
            let demuxer = try await MediaDemuxer.open(cache)
            let plan = try await BridgePlan(reading: demuxer, support: support, showsHDR: showsHDR)
            if !plan.omittedAudio.isEmpty {
                Log.playback.info("bridge: audio left out: \(plan.omittedAudio.joined(separator: ", "), privacy: .public)")
            }
            let keyframes = try await demuxer.keyframes()
            return BridgeSession(
                plan: plan, keyframes: keyframes, cache: cache,
                demuxers: DemuxerPool(first: demuxer, cache: cache, keyframes: keyframes),
                fragmentLimits: fragmentLimits)
        } catch let failure
            where failure is MediaDemuxer.OpenFailure || failure is MediaDemuxer.ReadFailure
            || failure is SegmentWriter.Failure {
            throw BridgeRefusal.unreadable(detail: "\(failure)")
        }
    }

    var entryPath: String { BridgeResource.master.path }

    func role(of path: String) -> String? {
        BridgeResource(path: path) != nil ? path : nil
    }

    /// What the session cost, from the requests the server answered for it.
    func report(of records: [RequestRecord]) -> BridgeReport {
        BridgeReport(
            records: records, bytesFetched: cache.bytes.fetched, memory: memory.peaks, readsRunning: reads.count)
    }

    func resource(at path: String) async throws -> ServedResource? {
        guard let resource = BridgeResource(path: path) else { return nil }
        switch resource {
        case .master:
            return .init(Data(HLSPlaylist.master(for: plan).utf8), contentType: HLSPlaylist.mediaType)
        case .playlist(let id):
            return plan.track(id).map {
                .init(Data(HLSPlaylist.media(id, of: $0).utf8), contentType: HLSPlaylist.mediaType)
            }
        case .initSegment(let id):
            return plan.track(id).map { .init($0.initSegment, contentType: "video/mp4") }
        case .mediaSegment(let id, let index):
            guard let track = plan.track(id), track.segments.indices.contains(index) else { return nil }
            let segment = track.segments[index]
            let rendition = track.rendition
            let takingLaterAudio = id != .video && index == track.segments.count - 1
            let (demuxers, limits, reads, memory, cache) = (demuxers, fragmentLimits, reads, memory, cache)
            return .init(contentType: "video/mp4") {
                let channel = FragmentChannel(heldChanged: memory.channelsHold)
                let handedOver: @Sendable () -> Void = { memory.sample(cacheKept: cache.bytes.kept) }
                reads.start(channel) {
                    do {
                        try await demuxers.using {
                            try await $0.write(
                                segment, of: rendition, takingLaterAudio: takingLaterAudio, limits: limits,
                                into: channel, handedOver: handedOver)
                        }
                        channel.finish(.success(()))
                    } catch {
                        channel.finish(.failure(error))
                    }
                }
                return channel
            }
        }
    }
}

extension MediaDemuxer {
    /// Reads, writes and hands over one segment as one call on the demuxer's queue, which
    /// blocks while `channel` is full. Packets of other streams are dropped as they are read.
    fileprivate func write(
        _ segment: BridgePlan.Segment, of rendition: Rendition, takingLaterAudio: Bool, limits: FragmentLimits,
        into channel: FragmentChannel, handedOver: @escaping @Sendable () -> Void
    ) throws {
        let writer = try FragmentWriter(
            rendition, lastingUntil: rendition.stream.kind == .video ? nil : segment.end, limits: limits)
        let before = bytesFetched
        let sink = SegmentSink(
            writer: writer, channel: channel, fetched: { self.bytesFetched - before }, handedOver: handedOver)
        defer { sink.countFetched() }
        try read(
            rendition.stream.index, from: segment.entries.lowerBound, to: segment.entries.upperBound,
            takingLaterAudio: takingLaterAudio, clock: rendition.clock, into: sink)
        try sink.handOver(try writer.finish())
    }
}

/// A segment's packets on their way into its writer, and its fragments on to the channel.
private final class SegmentSink: PacketSink {
    let writer: FragmentWriter
    let channel: FragmentChannel
    /// What the segment's read has fetched from the source so far.
    let fetched: () -> Int
    let handedOver: () -> Void

    init(writer: FragmentWriter, channel: FragmentChannel, fetched: @escaping () -> Int, handedOver: @escaping () -> Void) {
        self.writer = writer
        self.channel = channel
        self.fetched = fetched
        self.handedOver = handedOver
    }

    var isCancelled: Bool { channel.isCancelled }

    func accept(_ packet: DemuxedPacket) throws {
        if let fragment = try writer.append(packet) { try handOver(fragment) }
    }

    func handOver(_ fragment: Data) throws {
        countFetched()
        try channel.put(fragment)
        handedOver()
    }

    func countFetched() {
        channel.setBytesFetched(fetched())
    }
}

/// The segment reads a session has running, so a stop can cancel them and wait for them to
/// return.
final class SegmentReads: Sendable {
    private struct State {
        var running: [Int: (channel: FragmentChannel, task: Task<Void, Never>)] = [:]
        var started = 0
        var isStopped = false
    }

    private let state = Mutex(State())

    var count: Int { state.withLock { $0.running.count } }

    /// A read asked for after `stop` is cancelled before it starts.
    func start(_ channel: FragmentChannel, _ read: @escaping @Sendable () async -> Void) {
        // The task removes itself under the same lock, so it cannot do so before it is in.
        let started = state.withLock { state in
            guard !state.isStopped else { return false }
            state.started += 1
            let id = state.started
            state.running[id] = (channel, Task {
                await read()
                self.state.withLock { _ = $0.running.removeValue(forKey: id) }
            })
            return true
        }
        if !started { channel.cancel() }
    }

    /// Cancels every read. True on the first call only.
    func stop() -> Bool {
        let running = state.withLock { state in
            defer { state.isStopped = true }
            return state.isStopped ? nil : Array(state.running.values)
        }
        running?.forEach { $0.channel.cancel() }
        return running != nil
    }

    func allReturned() async {
        for read in state.withLock({ $0.running.values.map(\.task) }) { await read.value }
    }
}
