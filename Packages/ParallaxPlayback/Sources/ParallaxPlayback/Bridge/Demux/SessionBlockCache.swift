import Foundation
import ParallaxCore
import Synchronization

/// The parts of one file read last, shared by every demuxer reading it.
///
/// A segment's audio is read where its video was, and AVPlayer asks for both at once, each from
/// a demuxer of its own. Without the shared blocks a file is fetched once per track as it plays.
///
/// libavformat calls back synchronously, on each demuxer's queue, so a read here blocks its
/// thread until the block is in. Two demuxers asking for one block share one fetch.
final class SessionBlockCache: @unchecked Sendable {
    static let defaultBlockSize = 1 << 18
    /// A segment and the one before it took 13 to 21 MB together in the 4K files measured.
    static let defaultBytesKept = 64 << 20
    /// 2 MB, what direct play asks for at a time. Each request to an SMB share opens and closes
    /// the file, so a segment read 256 KB at a time took longer than AVPlayer waits for one.
    static let defaultBlocksPerRead = 8

    let size: Int64
    let blockSize: Int

    private let reader: any RandomAccessReading
    private let blocksKept: Int
    private let blocksPerRead: Int
    /// Guards everything below. A waiter releases it while it waits, so the fetch it waits for
    /// can publish.
    private let condition = NSCondition()
    private var kept: [Int64: (data: Data, used: Int)] = [:]
    private var keptBytes = 0
    private var fetchedBytes = 0
    private var uses = 0
    private var fetching: [Int64: Fetch] = [:]

    /// One request to the reader, for one or more blocks. Its waiters take the blocks from it,
    /// not from `kept`, which may have dropped them by the time they wake.
    private final class Fetch {
        var result: Result<[Int64: Data], any Error>?
    }

    init(
        reader: any RandomAccessReading, size: UInt64, blockSize: Int = defaultBlockSize,
        bytesKept: Int = defaultBytesKept, blocksPerRead: Int = defaultBlocksPerRead
    ) {
        self.reader = reader
        self.size = Int64(clamping: size)
        self.blockSize = blockSize
        blocksKept = max(bytesKept / blockSize, 1)
        self.blocksPerRead = blocksPerRead
    }

    /// What the blocks kept hold now, and every byte fetched from the reader so far.
    var bytes: (kept: Int, fetched: Int) {
        condition.lock()
        defer { condition.unlock() }
        return (keptBytes, fetchedBytes)
    }

    /// Block `index`, which is shorter than `blockSize` where the file ends or the reader
    /// answered short. `fetched` grows by what this call fetched from the reader itself. Blocks
    /// the calling thread, which must not be one of the cooperative pool's.
    func block(_ index: Int64, fetched: inout Int) -> Result<Data, any Error> {
        condition.lock()
        while true {
            if let block = kept[index] {
                uses += 1
                kept[index] = (block.data, uses)
                condition.unlock()
                return .success(block.data)
            }
            guard let fetch = fetching[index] else { break }
            while fetch.result == nil { condition.wait() }
            if case .failure(let error)? = fetch.result {
                condition.unlock()
                return .failure(error)
            }
            if case .success(let blocks)? = fetch.result, let data = blocks[index] {
                condition.unlock()
                return .success(data)
            }
            // The reader answered short of this block: it is asked for again.
        }

        // Reading on from the block before, the read takes the blocks after too, up to one
        // that is kept or on its way.
        let present = { (index: Int64) in self.kept[index] != nil || self.fetching[index] != nil }
        let last = (size - 1) / Int64(blockSize)
        var count: Int64 = 1
        if present(index - 1) {
            while count < blocksPerRead, index + count <= last, !present(index + count) { count += 1 }
        }
        let fetch = Fetch()
        for asked in index..<index + count { fetching[asked] = fetch }
        condition.unlock()

        let result = uncached(at: index * Int64(blockSize), length: Int(count) * blockSize).map { data in
            Dictionary(uniqueKeysWithValues: stride(from: 0, to: data.count, by: blockSize).map { start in
                (index + Int64(start / blockSize),
                 data.subdata(in: data.startIndex + start..<data.startIndex + min(start + blockSize, data.count)))
            })
        }

        condition.lock()
        fetch.result = result
        for asked in index..<index + count { fetching[asked] = nil }
        if case .success(let blocks) = result {
            let read = blocks.values.reduce(0) { $0 + $1.count }
            fetchedBytes += read
            fetched += read
            // A block that came back short is kept only where the file ends: elsewhere the next
            // read asks for it again.
            for (read, data) in blocks
            where Int64(data.count) == min(Int64(blockSize), size - read * Int64(blockSize)) {
                uses += 1
                keptBytes += data.count - (kept[read]?.data.count ?? 0)
                kept[read] = (data, uses)
            }
            while kept.count > blocksKept, let oldest = kept.min(by: { $0.value.used < $1.value.used }) {
                keptBytes -= oldest.value.data.count
                kept[oldest.key] = nil
            }
        }
        condition.broadcast()
        condition.unlock()
        return result.map { $0[index] ?? Data() }
    }

    /// Straight from the reader, kept nowhere. `fetched` grows by what it read. Blocks the
    /// calling thread.
    func uncached(at offset: Int64, length: Int, fetched: inout Int) -> Result<Data, any Error> {
        let result = uncached(at: offset, length: length)
        if case .success(let data) = result {
            fetched += data.count
            condition.lock()
            fetchedBytes += data.count
            condition.unlock()
        }
        return result
    }

    private func uncached(at offset: Int64, length: Int) -> Result<Data, any Error> {
        let answer = Mutex<Result<Data, any Error>>(.success(Data()))
        let answered = DispatchSemaphore(value: 0)
        Task.detached { [reader] in
            let result: Result<Data, any Error>
            do {
                result = .success(try await reader.read(offset: UInt64(offset), length: length))
            } catch {
                result = .failure(error)
            }
            answer.withLock { $0 = result }
            answered.signal()
        }
        answered.wait()
        return answer.withLock { $0 }
    }
}
