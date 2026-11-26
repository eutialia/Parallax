import AVFoundation
import Foundation
import Synchronization
import Testing
import ParallaxCore
import ParallaxCoreTestSupport
import ParallaxTestScaling
import ParallaxPlayback

/// A delivery of a file too large to read whole, and of reads that stick or fail once it plays.
@Suite("MediaDelivery — a large file, and reads that stick or fail", .serialized, .scaledTimeLimit())
struct MediaDeliveryLargeFileTests {

    /// Sampled until no stretch of 8 MB is left unread, and on a share slow enough that the time
    /// for sampling is up once the demuxer first reads, which then samples only where a
    /// segment would be larger than 256 MB.
    @MainActor
    @Test("a file over 256 MB starts playing before all its keyframes are listed", arguments: [false, true])
    func largeFileStartsBeforeItsKeyframesAreListed(timeRunsOut: Bool) async throws {
        let reader = try PaddedTransportStream()
        let clock = TestClock()
        let opening = Task { try await DeliveredFile.start(reading: reader, named: "recording.ts", clock: clock) }
        if timeRunsOut {
            // The probe's look, then the demuxer's first.
            await reader.awaitReads(2)
            clock.advance(by: .milliseconds(2500))
        }
        let file = try await opening.value
        let readToOpen = reader.bytesRead
        let segments = try await file.segmentSeconds(of: "v.m3u8")
        let played = try await PlayedFile(file)
        let fromStart = await played.framesShown(for: .seconds(3))
        let afterSeek = await played.framesShown(from: 40.5, for: .seconds(2))
        await played.stop()

        #expect(reader.size > 256 << 20)
        #expect(readToOpen < reader.size / (timeRunsOut ? 3 : 1), "\(readToOpen >> 20) MB of \(reader.size >> 20) MB read to open")
        // Thirty keyframes two seconds apart, half of them 2 MB apart.
        #expect(segments.count < 30, "\(segments)")
        #expect(abs(segments.reduce(0, +) - 60) < 0.1, "\(segments)")
        #expect(fromStart.count > 48, "\(fromStart)")
        #expect(fromStart.first?.number == 0)
        #expect(fromStart.filter { !$0.isTheSourceFrameForItsTime }.isEmpty, "\(fromStart)")
        #expect(afterSeek.first?.number == 972, "\(afterSeek)")
        #expect(afterSeek.filter { !$0.isTheSourceFrameForItsTime }.isEmpty, "\(afterSeek)")
    }

    @Test("stopping a bridged delivery while a read is stuck returns within 2 s, and stopping it again does nothing")
    func stopWhileAReadIsStuck() async throws {
        let clock = TestClock()
        let reader = try PaddedTransportStream()
        let file = try await DeliveredFile.start(reading: reader, named: "recording.ts", clock: clock)
        let segments = try await file.segmentSeconds(of: "v.m3u8")
        reader.wedgeReads()
        let fetch = Task { try? await file.bytes("v-\(segments.count / 2).m4s") }
        await reader.awaitWedgedRead()

        let stop = Task { await file.stop() }
        try await clock.waitForSleep(dueIn: .seconds(2))
        clock.advance(by: .seconds(2))
        await stop.value
        await file.stop()

        #expect(clock.pendingSleeps.isEmpty, "\(clock.pendingSleeps)")
        fetch.cancel()
        reader.release()
    }

    /// A read that fails before the segment's first fragment is ready, and one that fails after
    /// it was sent. A segment there is 16 MB of the file, and its first second 8 MB.
    @Test("when a segment's read fails partway, AVPlayer gets a response it cannot mistake for a whole segment",
          arguments: [(4 << 20, "HTTP/1.1 500 Internal Server Error"), (12 << 20, "HTTP/1.1 200 OK")])
    func segmentReadFailingPartway(failingAfter bytes: Int, startsAs status: String) async throws {
        let reader = try PaddedTransportStream()
        let file = try await DeliveredFile.start(reading: reader, named: "recording.ts", clock: TestClock())
        // The first segment past the opening read, in the part of the file 16 MB a keyframe.
        let path = "v-2.m4s"
        let whole = try await file.bytes(path)
        await file.stop()

        let failing = try PaddedTransportStream()
        let delivery = try await DeliveredFile.start(reading: failing, named: "recording.ts", clock: TestClock())
        failing.failReads(after: bytes)
        let url = delivery.url(of: path)
        let request = "GET \(url.path) HTTP/1.1\r\nHost: \(url.host() ?? "")\r\nConnection: close\r\n\r\n"
        let response = try await rawHTTPExchange(with: url, sending: Data(request.utf8), timeout: .seconds(30))
        await delivery.stop()

        let head = String(decoding: response.prefix(while: { $0 != 0x0D }), as: UTF8.self)
        #expect(head == status)
        #expect(response.count < whole.count, "\(response.count) bytes of a \(whole.count)-byte segment")
        #expect(!response.suffix(5).elementsEqual(Data("0\r\n\r\n".utf8)), "the response ended as a whole one")
    }
}

/// `ts-h264-open-gop.ts`, sixty numbered seconds with a keyframe every two, padded with null
/// packets to 270 MB without storing them: its first half to 16 MB a keyframe, its second to
/// 2 MB. A recording with a varying bitrate, too large to read whole and sampled for its
/// keyframes, which the sampler lists only every 8 MB.
private final class PaddedTransportStream: RandomAccessReading, Sendable {
    private static let packet = 188
    private let source: Data
    /// Null packets after each source packet, in the first half and the second.
    private let padding = (first: 686, second: 85)
    private let half: Int
    let size: Int

    private let state = Mutex(State())
    private struct State {
        var bytesRead = 0
        var wedged = false
        var wedgedReads: [CheckedContinuation<Void, Never>] = []
        var arrivals: [CheckedContinuation<Void, Never>] = []
        var failingPast: Int?
        var bytesSinceArmed = 0
        var reads = 0
        var readWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    }

    init() throws {
        source = try BridgeFixture.data("ts-h264-open-gop.ts")
        let packets = source.count / Self.packet
        half = packets / 2
        size = (half * (padding.first + 1) + (packets - half) * (padding.second + 1)) * Self.packet
    }

    var bytesRead: Int { state.withLock { $0.bytesRead } }

    func awaitReads(_ count: Int) async {
        await withCheckedContinuation { continuation in
            let reached = state.withLock { state in
                if state.reads >= count { return true }
                state.readWaiters.append((count, continuation))
                return false
            }
            if reached { continuation.resume() }
        }
    }

    /// Every read from now on waits until `release`, cancellation included, as a read stuck in
    /// a socket does.
    func wedgeReads() { state.withLock { $0.wedged = true } }

    func awaitWedgedRead() async {
        await withCheckedContinuation { continuation in
            let arrived = state.withLock { state in
                if !state.wedgedReads.isEmpty { return true }
                state.arrivals.append(continuation)
                return false
            }
            if arrived { continuation.resume() }
        }
    }

    func release() {
        let parked = state.withLock { state in
            defer { state.wedged = false; state.wedgedReads = [] }
            return state.wedgedReads
        }
        parked.forEach { $0.resume() }
    }

    /// Reads fail once `bytes` more have been read, as a share does when its connection drops.
    func failReads(after bytes: Int) { state.withLock { $0.failingPast = bytes; $0.bytesSinceArmed = 0 } }

    var fileSize: UInt64 { get async throws { UInt64(size) } }

    func read(offset: UInt64, length: Int) async throws -> Data {
        let (wedged, reached) = state.withLock { state in
            state.reads += 1
            let reads = state.reads
            defer { state.readWaiters.removeAll { $0.count <= reads } }
            return (state.wedged, state.readWaiters.filter { $0.count <= reads }.map(\.continuation))
        }
        reached.forEach { $0.resume() }
        if wedged {
            await withCheckedContinuation { continuation in
                let arrivals = state.withLock { state in
                    state.wedgedReads.append(continuation)
                    defer { state.arrivals = [] }
                    return state.arrivals
                }
                arrivals.forEach { $0.resume() }
            }
        }
        let end = min(Int(offset) + length, size)
        guard Int(offset) < end else { return Data() }
        let failed = state.withLock { state -> Bool in
            if let limit = state.failingPast {
                guard state.bytesSinceArmed < limit else { return true }
                state.bytesSinceArmed += end - Int(offset)
            }
            state.bytesRead += end - Int(offset)
            return false
        }
        if failed { throw ShareGone() }
        return bytes(Int(offset)..<end)
    }

    struct ShareGone: Error {}

    private static let null = Data([0x47, 0x1F, 0xFF, 0x10]) + Data(repeating: 0xFF, count: packet - 4)

    /// The padded file's bytes in `range`, packet by packet.
    private func bytes(_ range: Range<Int>) -> Data {
        var data = Data(capacity: range.count)
        var packetIndex = range.lowerBound / Self.packet
        while packetIndex * Self.packet < range.upperBound {
            let packetStart = packetIndex * Self.packet
            let content = sourcePacket(at: packetIndex).map { source[source.startIndex + $0 * Self.packet..<source.startIndex + ($0 + 1) * Self.packet] }
                ?? Self.null[...]
            let lower = max(range.lowerBound, packetStart) - packetStart
            let upper = min(range.upperBound, packetStart + Self.packet) - packetStart
            data.append(content[content.startIndex + lower..<content.startIndex + upper])
            packetIndex += 1
        }
        return data
    }

    /// The source packet at the padded file's packet `index`, or nil for a null one.
    private func sourcePacket(at index: Int) -> Int? {
        let firstSpan = half * (padding.first + 1)
        if index < firstSpan {
            return index.isMultiple(of: padding.first + 1) ? index / (padding.first + 1) : nil
        }
        let place = index - firstSpan
        return place.isMultiple(of: padding.second + 1) ? half + place / (padding.second + 1) : nil
    }
}
