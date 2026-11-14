import Foundation
import ParallaxCore
import Synchronization

/// The most the bridge and the process held while a session streamed, sampled at each fragment
/// a segment read hands over. A jetsam kill never reaches the report at stop, so each time the
/// headroom first falls below a mark the sample writes a retained record of it.
final class BridgeMemory: Sendable {
    struct Peaks: Sendable, Equatable {
        /// The session's kept blocks and the fragments its channels hold.
        var bridge = 0
        var footprint = 0
        /// Nil where the system reports no limit, as on macOS.
        var lowestHeadroom: Int?
    }

    static let headroomMarks = [1 << 30, 500 << 20, 250 << 20]

    private let channelBytes = Atomic(0)
    private let state = Mutex((peaks: Peaks(), marksPassed: 0))

    var peaks: Peaks { state.withLock { $0.peaks } }

    /// A change in what the session's channels hold.
    func channelsHold(_ change: Int) {
        channelBytes.add(change, ordering: .relaxed)
    }

    func sample(cacheKept: Int) {
        let bridge = cacheKept + channelBytes.load(ordering: .relaxed)
        let footprint = DiagnosticsVitals.footprint()
        let headroom = DiagnosticsVitals.available()
        let passed = state.withLock { state in
            state.peaks.bridge = max(state.peaks.bridge, bridge)
            state.peaks.footprint = max(state.peaks.footprint, footprint)
            guard headroom > 0 else { return [Int]() }
            state.peaks.lowestHeadroom = min(state.peaks.lowestHeadroom ?? .max, headroom)
            let passed = Self.headroomMarks.dropFirst(state.marksPassed).prefix { headroom < $0 }
            state.marksPassed += passed.count
            return Array(passed)
        }
        for mark in passed {
            BridgeReport.log.mark("bridge: headroom below \(mark >> 20) MB, bridge holds \(bridge >> 20) MB")
        }
    }
}

/// What one bridged delivery cost, from its request log, written once when it stops.
struct BridgeReport: Equatable, CustomStringConvertible {
    static let log = Log.retained(category: "Bridge")

    let requests: Int
    let bytesServed: Int
    /// From the source, by every segment read and the session's opening.
    let bytesFetched: Int
    let worstFirstByte: Duration?
    let dropped: Int
    let largestSegment: Int
    let memory: BridgeMemory.Peaks
    /// Segment reads still running when the report was taken.
    let readsRunning: Int

    init(records: [RequestRecord], bytesFetched: Int, memory: BridgeMemory.Peaks, readsRunning: Int) {
        requests = records.count
        bytesServed = records.reduce(0) { $0 + $1.bytesSent }
        self.bytesFetched = bytesFetched
        worstFirstByte = records.compactMap(\.firstByte).max()
        dropped = records.count { $0.ending == .dropped }
        largestSegment = records.filter { $0.resource.hasSuffix(".m4s") }.map(\.bytesSent).max() ?? 0
        self.memory = memory
        self.readsRunning = readsRunning
    }

    var description: String {
        let ratio = bytesServed > 0 ? String(format: "%.2f", Double(bytesFetched) / Double(bytesServed)) : "-"
        let first = worstFirstByte.map { "\(Int(($0 / .milliseconds(1)).rounded())) ms" } ?? "-"
        let headroom = memory.lowestHeadroom.map { "\($0 >> 20) MB" } ?? "-"
        return "bridge: \(requests) requests, \(bytesServed >> 20) MB served, \(bytesFetched >> 20) MB read "
            + "(\(ratio)x), worst first byte \(first), \(dropped) dropped, largest segment "
            + "\(largestSegment >> 20) MB, bridge peak \(memory.bridge >> 20) MB, footprint peak "
            + "\(memory.footprint >> 20) MB, lowest headroom \(headroom), \(readsRunning) reads not returned"
    }
}
