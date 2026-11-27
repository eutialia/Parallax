import Foundation
import Synchronization
import Testing
import ParallaxCore

/// A recording stretched with filler its demuxer passes over, computed as it is read and never
/// stored: after each of its units, a transport stream's packets or a program stream's packs, a
/// run of filler units. A share that can also stick, fail, and say what was read of it.
final class PaddedRecording: RandomAccessReading, Sendable {
    /// How many filler units follow each unit.
    enum Padding: Sendable {
        /// One number after each unit of the first half, another after each of the second.
        case halves(Int, Int)
        /// The first and last quarter as stored, where libavformat reads to describe the
        /// streams and to time the file, and the same number after each unit between them,
        /// enough to take the file past `bytes`.
        case middleHalf(past: Int)
    }

    private let source: Data
    /// Each unit of the source, and where it starts in the padded file.
    private let units: [Range<Int>]
    private let starts: [Int]
    private let filler: Data
    let size: Int

    private let state = Mutex(State())
    private struct State {
        var bytesRead = 0
        /// Reads that reach past this offset wait until `release`.
        var wedgedPast: Int?
        /// The furthest byte read since the last `takeFurthest`.
        var furthest = 0
        var wedgedReads: [CheckedContinuation<Void, Never>] = []
        var arrivals: [CheckedContinuation<Void, Never>] = []
        var failingPast: Int?
        var bytesSinceArmed = 0
        var reads = 0
        var readWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    }

    private init(source: Data, units: [Range<Int>], filler: Data, padding: Padding) {
        let fillers: (Int) -> Int
        switch padding {
        case .halves(let first, let second):
            fillers = { $0 < units.count / 2 ? first : second }
        case .middleHalf(let least):
            let kept = units.count / 4
            let middle = units.count - 2 * kept
            let each = (least - source.count + middle * filler.count - 1) / (middle * filler.count)
            fillers = { (kept..<kept + middle).contains($0) ? each : 0 }
        }
        let lengths = units.indices.map { units[$0].count + fillers($0) * filler.count }
        self.source = source
        self.units = units
        self.filler = filler
        starts = Array(lengths.reduce(into: [0]) { $0.append($0[$0.count - 1] + $1) }.dropLast())
        size = lengths.reduce(0, +)
    }

    /// `ts-h264-open-gop.ts`, sixty numbered seconds with a keyframe every two, padded to 270
    /// MB: its first half to 16 MB a keyframe, its second to 2 MB. A recording with a varying
    /// bitrate, too large to read whole and sampled for its keyframes, which the sampler lists
    /// only every 8 MB.
    convenience init() throws {
        try self.init(transportStream: BridgeFixture.data("ts-h264-open-gop.ts"), packetSize: 188, padding: .halves(686, 85))
    }

    /// A transport stream of 188-byte packets, or a disc's of 192, which carry four bytes of
    /// arrival time, padded with null packets.
    convenience init(transportStream source: Data, packetSize: Int, padding: Padding) throws {
        try #require(source.count % packetSize == 0, "\(source.count) bytes is no whole number of \(packetSize)-byte packets")
        let null = Data(count: packetSize - 188) + Data([0x47, 0x1F, 0xFF, 0x10]) + Data(repeating: 0xFF, count: 184)
        let units = stride(from: 0, to: source.count, by: packetSize).map { $0..<$0 + packetSize }
        self.init(source: source, units: units, filler: null, padding: padding)
    }

    /// An MPEG-2 program stream, padded with 2,048-byte packets of its padding stream, 0xBE,
    /// after its packs. A pack is its header, 14 bytes and its stuffing, then packets that each
    /// give their length.
    convenience init(programStream source: Data, padding: Padding) throws {
        let bytes = [UInt8](source)
        var packs: [Int] = []
        var at = 0
        while at + 6 <= bytes.count, bytes[at..<at + 3] == [0, 0, 1] {
            switch bytes[at + 3] {
            case 0xBA:
                packs.append(at)
                at += 14 + Int(bytes[at + 13] & 0x07)
            case 0xB9: at += 4
            default: at += 6 + (Int(bytes[at + 4]) << 8 | Int(bytes[at + 5]))
            }
        }
        try #require(at >= bytes.count - 4 && !packs.isEmpty, "the walk of the packs stopped at \(at) of \(bytes.count)")
        let paddingPacket = Data([0, 0, 1, 0xBE, 0x07, 0xFA]) + Data(repeating: 0xFF, count: 2042)
        let units = zip(packs, packs.dropFirst() + [bytes.count]).map { $0..<$1 }
        self.init(source: source, units: units, filler: paddingPacket, padding: padding)
    }

    var bytesRead: Int { state.withLock { $0.bytesRead } }

    var readsStarted: Int { state.withLock { $0.reads } }

    func takeFurthest() -> Int { state.withLock { defer { $0.furthest = 0 }; return $0.furthest } }

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

    /// Every read from now on that reaches past `offset` waits until `release`, cancellation
    /// included, as a read stuck in a socket does.
    func wedgeReads(reachingPast offset: Int = -1) { state.withLock { $0.wedgedPast = offset } }

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
            defer { state.wedgedPast = nil; state.wedgedReads = [] }
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
            let wedged = state.wedgedPast.map { Int(offset) + length > $0 } ?? false
            return (wedged, state.readWaiters.filter { $0.count <= reads }.map(\.continuation))
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
            state.furthest = max(state.furthest, end)
            return false
        }
        if failed { throw ShareGone() }
        return bytes(Int(offset)..<end)
    }

    struct ShareGone: Error {}

    /// The padded file's bytes in `range`, unit by unit.
    private func bytes(_ range: Range<Int>) -> Data {
        var data = Data(capacity: range.count)
        var unit = (starts.lastIndex { $0 <= range.lowerBound })!
        var at = range.lowerBound
        while at < range.upperBound {
            let unitEnd = starts[unit] + units[unit].count
            let next = unit + 1 < starts.count ? starts[unit + 1] : size
            if at < unitEnd {
                let upper = min(range.upperBound, unitEnd)
                let from = source.startIndex + units[unit].lowerBound + at - starts[unit]
                data.append(source[from..<from + upper - at])
                at = upper
            } else if at < next {
                let place = (at - unitEnd) % filler.count
                let upper = min(range.upperBound, next, at + filler.count - place)
                data.append(filler[place..<place + upper - at])
                at = upper
            } else {
                unit += 1
            }
        }
        return data
    }
}
