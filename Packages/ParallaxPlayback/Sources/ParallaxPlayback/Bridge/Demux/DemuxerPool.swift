import Synchronization

/// The demuxers one file is read with: one per read in flight, so a video and an audio segment
/// are read at once, and a request that overlaps another (a prefetch, a retry on a new
/// connection, an AirPlay receiver beside the local player) never waits behind it.
final class DemuxerPool: Sendable {
    /// Enough for a video read and an audio read, each with a request overlapping it.
    static let idleKept = 4

    private let cache: SessionBlockCache
    private let keyframes: [IndexedKeyframe]
    private let idle: Mutex<[MediaDemuxer]>

    /// `first` made `keyframes`; the others are handed them, and read the header from `cache`.
    init(first: MediaDemuxer, cache: SessionBlockCache, keyframes: [IndexedKeyframe]) {
        self.cache = cache
        self.keyframes = keyframes
        idle = Mutex([first])
    }

    /// Runs `body` on a demuxer no other read is using.
    func using<Value>(_ body: (MediaDemuxer) async throws -> Value) async throws -> Value {
        let demuxer: MediaDemuxer
        if let kept = idle.withLock({ $0.popLast() }) {
            demuxer = kept
        } else {
            demuxer = try await MediaDemuxer.open(cache, keyframes: keyframes)
        }
        defer { idle.withLock { if $0.count < Self.idleKept { $0.append(demuxer) } } }
        return try await body(demuxer)
    }
}
