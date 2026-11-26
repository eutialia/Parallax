import Foundation
import Synchronization
import ParallaxCore

/// Counts what is read of `data`.
final class CountingReader: RandomAccessReading {
    let data: Data
    private let count = Mutex((bytes: 0, requests: 0))
    var bytesRead: Int { count.withLock { $0.bytes } }
    var requests: Int { count.withLock { $0.requests } }

    init(_ data: Data) { self.data = data }

    var fileSize: UInt64 { get async throws { UInt64(data.count) } }

    func read(offset: UInt64, length: Int) async throws -> Data {
        let read = try await InMemoryRandomAccessReader(data: data).read(offset: offset, length: length)
        count.withLock { $0 = (bytes: $0.bytes + read.count, requests: $0.requests + 1) }
        return read
    }
}

/// Fails the next read after `failNextRead`, as a share does when its connection drops.
final class FailingOnceReader: RandomAccessReading {
    struct Dropped: Error {}
    let data: Data
    private let failing = Mutex(false)

    init(data: Data) { self.data = data }

    func failNextRead() { failing.withLock { $0 = true } }

    var fileSize: UInt64 { get async throws { UInt64(data.count) } }

    func read(offset: UInt64, length: Int) async throws -> Data {
        if failing.withLock({ defer { $0 = false }; return $0 }) { throw Dropped() }
        return try await InMemoryRandomAccessReader(data: data).read(offset: offset, length: length)
    }
}
