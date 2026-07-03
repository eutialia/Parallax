import Foundation

/// Minimal random-access byte source for container probing (and the HTTP bridge).
/// Implementations must be safe to call from concurrent tasks.
public protocol RandomAccessReading: Sendable {
    /// Total size in bytes. May be re-read; a still-growing file may report a larger
    /// value on later calls — probing treats the first read as authoritative.
    var fileSize: UInt64 { get async throws }
    /// Reads up to `length` bytes at `offset`. A read past EOF returns the available
    /// prefix (possibly empty) rather than throwing, mirroring POSIX pread.
    func read(offset: UInt64, length: Int) async throws -> Data
}

/// In-memory backing for tests.
public struct InMemoryRandomAccessReader: RandomAccessReading {
    private let data: Data
    public init(data: Data) { self.data = data }
    public var fileSize: UInt64 { get async throws { UInt64(data.count) } }
    public func read(offset: UInt64, length: Int) async throws -> Data {
        guard offset < UInt64(data.count), length > 0 else { return Data() }
        let start = Int(offset)
        let end = min(start + length, data.count)
        return data.subdata(in: start..<end)
    }
}
