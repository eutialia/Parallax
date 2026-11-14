import Foundation
import Testing
import ParallaxCore
import ParallaxTestScaling
@testable import ParallaxPlayback

@Suite("SessionBlockCache", .scaledTimeLimit())
struct SessionBlockCacheTests {

    /// Holds every read until `open()`, and keeps what was asked.
    private actor GatedReader: RandomAccessReading {
        private let backing = InMemoryRandomAccessReader(data: Data(count: 1 << 20))
        private var isOpen = false
        private var held: [CheckedContinuation<Void, Never>] = []
        private var arrivalWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
        private(set) var asked: [(offset: UInt64, length: Int)] = []

        var fileSize: UInt64 { get async throws { try await backing.fileSize } }

        func read(offset: UInt64, length: Int) async throws -> Data {
            asked.append((offset, length))
            arrivalWaiters.filter { $0.count <= asked.count }.forEach { $0.continuation.resume() }
            arrivalWaiters.removeAll { $0.count <= asked.count }
            if !isOpen { await withCheckedContinuation { held.append($0) } }
            return try await backing.read(offset: offset, length: length)
        }

        /// Returns once `count` reads have arrived.
        func waitForReads(_ count: Int) async {
            if asked.count >= count { return }
            await withCheckedContinuation { arrivalWaiters.append((count, $0)) }
        }

        func open() {
            isOpen = true
            held.forEach { $0.resume() }
            held = []
        }
    }

    /// `block(index)` on a thread of its own, as a demuxer's queue calls it.
    private static func block(_ index: Int64, of cache: SessionBlockCache) async -> Result<Data, any Error> {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                var fetched = 0
                continuation.resume(returning: cache.block(index, fetched: &fetched))
            }
        }
    }

    @Test("a block asked for while it is being read is not read again")
    func blockAskedForDuringItsReadIsReadOnce() async throws {
        let reader = GatedReader()
        let cache = SessionBlockCache(reader: reader, size: 1 << 20, blockSize: 4096)

        async let first = Self.block(0, of: cache)
        await reader.waitForReads(1)
        async let second = Self.block(0, of: cache)
        // Time for the second ask to reach the reader, were it going to.
        try await Task.sleep(for: .milliseconds(50))
        await reader.open()

        #expect(try await first.get() == second.get())
        #expect(await reader.asked.count == 1)
    }

    @Test("a block read right after one still being read is read with the blocks after it, as reading on in order")
    func blockAfterOneInFlightReadsAhead() async throws {
        let reader = GatedReader()
        let cache = SessionBlockCache(reader: reader, size: 1 << 20, blockSize: 4096, blocksPerRead: 8)

        async let first = Self.block(0, of: cache)
        await reader.waitForReads(1)
        async let second = Self.block(1, of: cache)
        await reader.waitForReads(2)
        await reader.open()
        _ = try await (first.get(), second.get())

        #expect(await reader.asked.map { [$0.offset, UInt64($0.length)] } == [[0, 4096], [4096, 8 * 4096]])
    }
}
