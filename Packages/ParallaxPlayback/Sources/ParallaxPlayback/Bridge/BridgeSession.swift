import Foundation
import ParallaxCore
import Synchronization

/// Serves one bridged file: playlists from the plan, and each segment built from the file when
/// it is asked for. It keeps no segment between requests, so the same path always gives the
/// same bytes, in whatever order AVPlayer asks.
struct BridgeSession: MediaResponder {
    let plan: BridgePlan
    /// The video keyframes every segment's read starts from.
    let keyframes: [IndexedKeyframe]
    let reads = SegmentReads()
    let memory = BridgeMemory()
    let conversions = ConversionSpeeds()
    /// A hardware encoder opens only a few sessions at once, and AVPlayer's requests overlap.
    private let videoConversions = OneAtATime()
    private let stopwatch: @Sendable () -> @Sendable () -> Duration
    private let cache: SessionBlockCache
    private let demuxers: DemuxerPool

    /// Reads the file's headers, keyframe list and opening. Throws a `BridgeRefusal` for a file the
    /// bridge cannot deliver, and the reader's own error when a read fails.
    static func open(
        _ reader: any RandomAccessReading, support: AVPlayerSupport, showsHDR: Bool, listing: KeyframeListing,
        clock: any Clock<Duration>
    ) async throws -> BridgeSession {
        do {
            let cache = SessionBlockCache(reader: reader, size: try await reader.fileSize)
            let demuxer = try await MediaDemuxer.open(cache, listing: listing)
            let plan = try await BridgePlan(reading: demuxer, support: support, showsHDR: showsHDR)
            if !plan.omittedAudio.isEmpty {
                Log.playback.info("bridge: audio left out: \(plan.omittedAudio.joined(separator: ", "), privacy: .public)")
            }
            let keyframes = try await demuxer.keyframes()
            return BridgeSession(
                plan: plan, keyframes: keyframes, stopwatch: LocalMediaServer.stopwatch(on: clock), cache: cache,
                demuxers: DemuxerPool(first: demuxer, cache: cache, keyframes: keyframes))
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
            records: records, bytesFetched: cache.bytes.fetched, memory: memory.peaks, readsRunning: reads.count,
            conversionSpeeds: conversions.all)
    }

    func resource(at path: String) async -> ServedResource? {
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
            let (demuxers, reads, memory, cache) = (demuxers, reads, memory, cache)
            let (stopwatch, conversions, videoConversions) = (stopwatch, conversions, videoConversions)
            return .init(contentType: "video/mp4") {
                let channel = FragmentChannel(heldChanged: memory.channelsHold)
                let handedOver: @Sendable () -> Void = { memory.sample(cacheKept: cache.bytes.kept) }
                reads.start(channel) {
                    do {
                        let write = {
                            try await demuxers.using {
                                try await $0.write(
                                    segment, of: rendition, takingLaterAudio: takingLaterAudio,
                                    leadingSilence: index == 0 ? track.leadingSilence : nil,
                                    into: channel, handedOver: handedOver, stopwatch: stopwatch,
                                    converted: conversions.add)
                            }
                        }
                        if rendition.convertedVideo != nil {
                            try await videoConversions.run {
                                // Asked for before a seek, and no longer wanted by its turn.
                                if channel.isCancelled { throw CancellationError() }
                                try await write()
                            }
                        } else {
                            try await write()
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
    /// `leadingSilence` goes in front of the packets of a copied audio track's first segment.
    fileprivate func write(
        _ segment: BridgePlan.Segment, of rendition: Rendition, takingLaterAudio: Bool,
        leadingSilence: LeadingSilence?,
        into channel: FragmentChannel, handedOver: @escaping @Sendable () -> Void,
        stopwatch: @escaping @Sendable () -> @Sendable () -> Duration, converted: (Double) -> Void
    ) throws {
        let isCopiedVideo = if case .copy = rendition.delivery { rendition.stream.kind == .video } else { false }
        let writer = try FragmentWriter(rendition, lastingUntil: isCopiedVideo ? nil : segment.end, limits: .standard)
        let before = bytesFetched
        let sink = SegmentSink(
            writer: writer, channel: channel, fetched: { self.bytesFetched - before }, handedOver: handedOver)
        defer { sink.countFetched() }
        let (lower, upper) = (segment.entries.lowerBound, segment.entries.upperBound)
        switch rendition.delivery {
        case .copy:
            if let leadingSilence {
                for (start, frame) in zip(leadingSilence.starts, leadingSilence.frames) {
                    try sink.accept(frame, isKeyframe: true, at: start, lasting: leadingSilence.frameLength)
                }
            }
            try read(
                rendition.stream.index, from: lower, to: upper, takingLaterAudio: takingLaterAudio,
                clock: rendition.clock, into: sink)
        case .video(let video):
            let ticks = rendition.clock.ticks(at: segment.start)
                ..< (upper == (try keyframes().count) ? .max : rendition.clock.ticks(at: segment.end))
            let conversion = try VideoConversion(
                video, of: rendition, ticks: ticks, stopwatch: stopwatch, cancelled: { sink.isCancelled },
                into: sink.accept)
            try read(rendition.stream.index, from: lower, to: upper, into: conversion)
            try conversion.finish()
            if let speed = conversion.speed { converted(speed) }
        case .audio(let audio):
            let ticks = (lower == 0 ? .min : rendition.clock.ticks(at: segment.start))
                ..< (takingLaterAudio ? .max : rendition.clock.ticks(at: segment.end))
            let conversion = try AudioConversion(
                audio, of: rendition, ticks: ticks, firstPicture: lower == 0 ? rendition.clock.ticks(at: segment.start) : nil,
                stopwatch: stopwatch, cancelled: { sink.isCancelled },
                into: { try sink.accept($0, isKeyframe: true, at: $1, lasting: $2) })
            try read(
                rendition.stream.index, from: lower, to: upper, takingLaterAudio: takingLaterAudio,
                warmUp: BridgePlan.audioWarmUp, into: conversion)
            try conversion.finish()
            if let speed = conversion.speed { converted(speed) }
        }
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

    func accept(_ packet: MediaPacket) throws {
        if let fragment = try writer.append(packet) { try handOver(fragment) }
    }

    /// A sample an encoder made, timed in the rendition's ticks.
    func accept(_ data: Data, isKeyframe: Bool, at tick: Int64, lasting length: Int64?) throws {
        if let fragment = try writer.append(data, isKeyframe: isKeyframe, at: tick, lasting: length) {
            try handOver(fragment)
        }
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
