import Foundation
import Testing
import ParallaxCoreTestSupport
import ParallaxCore
@testable import ParallaxPlayback

@Suite("SessionBlockCache", .timeLimit(.minutes(1)))
struct SessionBlockCacheTests {

    /// A file's blocks, some kept or on their way, and one asked for.
    private struct Asked: CustomStringConvertible {
        let index: Int64
        let last: Int64
        let perRead: Int
        let present: Set<Int64>

        static func random(using generator: inout SeededGenerator) -> Asked {
            let last = Int64.random(in: 0...40, using: &generator)
            let index = Int64.random(in: 0...last, using: &generator)
            let density = Double.random(in: 0...1, using: &generator)
            let present = Set((0...last).filter { $0 != index && Double.random(in: 0...1, using: &generator) < density })
            return Asked(index: index, last: last, perRead: Int.random(in: 1...12, using: &generator), present: present)
        }

        var count: Int64 {
            SessionBlockCache.blocksRead(for: index, last: last, perRead: perRead, isPresent: present.contains)
        }

        var description: String { "block \(index) of 0...\(last), \(perRead) a read, present \(present.sorted())" }
    }

    private static let cases = 400

    @Test("a read takes the block asked for and, reading on from the block before, the blocks after it up to the first one kept or on its way, the file's end, or a read's worth")
    func aReadTakesTheBlocksAfterOnlyReadingOn() {
        let seed = UInt64(0x626C_6F63_6B73)
        var generator = SeededGenerator(seed: seed)
        for _ in 0..<Self.cases {
            let asked = Asked.random(using: &generator)
            let count = asked.count
            let taken = asked.index..<asked.index + count
            let readingOn = asked.present.contains(asked.index - 1)
            let following = asked.index + count
            let endsWhereItMust = count == Int64(asked.perRead) || following > asked.last
                || asked.present.contains(following)

            #expect(count >= 1 && count <= Int64(asked.perRead), "seed \(seed): \(asked) read \(count)")
            #expect(taken.upperBound - 1 <= asked.last, "seed \(seed): \(asked) read \(count)")
            #expect(!taken.contains { asked.present.contains($0) }, "seed \(seed): \(asked) read \(count)")
            #expect(readingOn || count == 1, "seed \(seed): \(asked) read \(count)")
            #expect(!readingOn || endsWhereItMust, "seed \(seed): \(asked) read \(count)")
        }
    }

    /// Holds every read until `open()`, and keeps what was asked.
    private actor GatedReader: RandomAccessReading {
        private let backing = InMemoryRandomAccessReader(data: Data(count: 16 << 20))
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

    /// What this saves is a round trip to the share for each block, which a delivery's ends see
    /// only as time.
    @Test("a block read right after one still being read is read with the blocks after it, as reading on in order")
    func blockAfterOneInFlightReadsAhead() async throws {
        let reader = GatedReader()
        let cache = SessionBlockCache(reader: reader, size: 16 << 20)
        let block = UInt64(SessionBlockCache.blockSize)

        async let first = Self.block(0, of: cache)
        await reader.waitForReads(1)
        async let second = Self.block(1, of: cache)
        await reader.waitForReads(2)
        await reader.open()
        _ = try await (first.get(), second.get())

        #expect(await reader.asked.map { [$0.offset, UInt64($0.length)] }
            == [[0, block], [block, UInt64(SessionBlockCache.blocksPerRead) * block]])
    }
}
