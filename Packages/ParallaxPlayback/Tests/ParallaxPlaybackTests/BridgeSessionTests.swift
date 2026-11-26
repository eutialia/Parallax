import AVFoundation
import Foundation
import ParallaxCore
import Synchronization
import Testing
import ParallaxTestScaling
@testable import ParallaxPlayback

@Suite("BridgeSession", .scaledTimeLimit())
struct BridgeSessionTests {

    private static func session(
        _ name: String, fragmentLimits: FragmentLimits = .standard, support: AVPlayerSupport = BridgeFixture.everyDecoder
    ) async throws -> BridgeSession {
        try await BridgeSession.open(
            InMemoryRandomAccessReader(data: BridgeFixture.data(name)), support: support, showsHDR: true,
            fragmentLimits: fragmentLimits)
    }

    private static func bytes(_ session: BridgeSession, _ path: String) async throws -> Data {
        try await #require(try await session.resource(at: path)).bytes()
    }

    @Test("the first fragment of a 32-second segment is handed over before the segment's last packet is read")
    func firstFragmentComesBeforeTheSegmentIsRead() async throws {
        let reader = CountingReader(data: try BridgeFixture.data("long-span"))
        // Blocks of 4 KB, few kept, and fragments of 16 KB: the segment is 141 KB.
        let session = try await BridgeSession.open(
            reader, support: BridgeFixture.everyDecoder, showsHDR: true, blockSize: 4096, bytesKept: 64 << 10,
            fragmentLimits: FragmentLimits(bytes: 16 << 10, duration: .seconds(Int64.max)))
        try #require(session.plan.video.segments[0].entries == 0..<1)
        guard case .streamed(let produce) = try #require(try await session.resource(at: "v-0.m4s")).body else {
            Issue.record("a media segment is streamed")
            return
        }
        _ = reader.takeFurthest()

        let producer = produce()
        let first = try await producer.next()
        let furthest = reader.takeFurthest()
        producer.cancel()

        #expect(first?.isEmpty == false)
        #expect(furthest < session.keyframes[1].position)
    }

    @Test("a converted audio segment reads half a second ahead of its span, not the whole span before it")
    func convertedAudioReadsLittleBeforeItsSpan() async throws {
        let reader = CountingReader(data: try BridgeFixture.data("ts-mp2.ts"))
        // Sampled as a large recording is: a listed keyframe every 300 KB or so, five seconds apart.
        let session = try await BridgeSession.open(
            reader, support: BridgeFixture.everyDecoder, showsHDR: true, blockSize: 4096, bytesKept: 64 << 10,
            listing: .init(wholeReadSize: 0, sampling: .init(densestSpacing: 300_000, largestSegment: 300_000)))
        let segment = try #require(session.plan.audio.first?.segments.dropFirst().first)
        try #require(session.plan.audio[0].segments.count > 2)
        let span = Int(
            session.keyframes[segment.entries.upperBound].position - session.keyframes[segment.entries.lowerBound].position)
        let readAtOpen = reader.bytesRead

        _ = try await Self.bytes(session, "a0-1.m4s")

        #expect(reader.bytesRead - readAtOpen < span + span / 2, "\(reader.bytesRead - readAtOpen) bytes for a span of \(span)")
    }

    @Test("a segment read cancelled after its first fragment fetches at most one more read, and returns")
    func cancelledSegmentStopsItsRead() async throws {
        let reader = CountingReader(data: try BridgeFixture.data("long-span"))
        let session = try await BridgeSession.open(
            reader, support: BridgeFixture.everyDecoder, showsHDR: true, blockSize: 4096, bytesKept: 64 << 10,
            fragmentLimits: FragmentLimits(bytes: 16 << 10, duration: .seconds(Int64.max)))
        guard case .streamed(let produce) = try #require(try await session.resource(at: "v-0.m4s")).body else {
            Issue.record("a media segment is streamed")
            return
        }

        let producer = produce()
        _ = try await producer.next()
        producer.cancel()
        let readAtCancel = reader.bytesRead
        await session.reads.allReturned()

        #expect(session.reads.count == 0)
        #expect(reader.bytesRead - readAtCancel <= SessionBlockCache.defaultBlocksPerRead * 4096)
        #expect(session.report(of: []).bytesFetched == reader.bytesRead)
    }

    private final class CountingReader: RandomAccessReading {
        let data: Data
        private let count = Mutex((bytes: 0, requests: 0))
        /// The furthest byte read since the last `takeFurthest`.
        private let furthest = Mutex<Int64>(0)
        var bytesRead: Int { count.withLock { $0.bytes } }
        var requests: Int { count.withLock { $0.requests } }

        func takeFurthest() -> Int64 { furthest.withLock { defer { $0 = 0 }; return $0 } }

        init(data: Data) { self.data = data }

        var fileSize: UInt64 { get async throws { UInt64(data.count) } }

        func read(offset: UInt64, length: Int) async throws -> Data {
            let read = try await InMemoryRandomAccessReader(data: data).read(offset: offset, length: length)
            count.withLock { $0 = (bytes: $0.bytes + read.count, requests: $0.requests + 1) }
            furthest.withLock { $0 = max($0, Int64(offset) + Int64(read.count)) }
            return read
        }
    }
}
