import Foundation
import Testing
import ParallaxPlaybackTestSupport
@testable import ParallaxPlayback

/// Where the probe reads an MP4's samples to look for B slices: the byte range of each, from
/// the sample table's sizes, chunk runs and chunk offsets. No muxer writes a fixed-size `stsz`
/// for video or a `co64` into a file small enough to be a fixture, so these hold for tables
/// built here.
@Suite("MediaDelivery — where the probe finds an MP4's samples")
struct MediaDeliverySampleRangeTests {
    private typealias Fixture = ISOBMFFFixtures
    private typealias SampleRange = MediaProbe.SampleRange

    /// A sample table: each sample's size, the `stsc` runs of samples per chunk, and where each
    /// chunk starts.
    private struct Table {
        let sizes: [UInt32]
        let runs: [(firstChunk: UInt32, samplesPerChunk: UInt32)]
        let offsets: [UInt64]
    }

    private static func bigEndian<Value: FixedWidthInteger>(_ values: [Value]) -> Data {
        values.reduce(into: Data()) { data, value in withUnsafeBytes(of: value.bigEndian) { data.append(contentsOf: $0) } }
    }

    /// A box whose payload starts with a version and flags of zero.
    private static func fullBox(_ type: String, _ payload: Data) -> Data { Fixture.box(type, Data(count: 4) + payload) }

    private static func stsz(_ sizes: [UInt32]) -> Data { fullBox("stsz", bigEndian([0, UInt32(sizes.count)] + sizes)) }

    private static func stsz(fixed size: UInt32, count: Int) -> Data { fullBox("stsz", bigEndian([size, UInt32(count)])) }

    private static func stsc(_ table: Table) -> Data {
        fullBox("stsc", bigEndian([UInt32(table.runs.count)] + table.runs.flatMap { [$0.firstChunk, $0.samplesPerChunk, 1] }))
    }

    private static func stco(_ offsets: [UInt64]) -> Data {
        fullBox("stco", bigEndian([UInt32(offsets.count)] + offsets.map { UInt32($0) }))
    }

    private static func co64(_ offsets: [UInt64]) -> Data {
        fullBox("co64", bigEndian([UInt32(offsets.count)]) + bigEndian(offsets))
    }

    private static func ranges(_ stbl: Data, from first: Int, count: Int) throws -> [SampleRange] {
        try #require(MediaProbe.sampleRanges(from: first, count: count, in: stbl, stbl: 0..<stbl.count))
    }

    /// Up to 40 chunks in up to five runs, some of them of empty chunks, and a size table a
    /// few samples longer or shorter than the chunks hold.
    private static func table(using random: inout SplitMixRandom, offsetsBelow limit: UInt64) -> Table {
        let chunkCount = Int.random(in: 1...40, using: &random)
        let laterRuns = chunkCount == 1 ? [] : (2...chunkCount).shuffled(using: &random)
            .prefix(Int.random(in: 0...4, using: &random)).sorted()
        let runs = ([1] + laterRuns).map { (firstChunk: UInt32($0), samplesPerChunk: UInt32.random(in: 0...6, using: &random)) }
        let held = (1...chunkCount).reduce(0) { total, chunk in
            total + Int(runs.last { $0.firstChunk <= chunk }!.samplesPerChunk)
        }
        let sampleCount = max(1, held + Int.random(in: -3...3, using: &random))
        return Table(
            sizes: (0..<sampleCount).map { _ in UInt32.random(in: 0...5000, using: &random) },
            runs: runs,
            offsets: (0..<chunkCount).map { _ in UInt64.random(in: 0..<limit, using: &random) })
    }

    /// Each chunk's samples one after another from its offset, for every chunk in turn.
    private static func naiveRanges(of table: Table, from first: Int, count: Int) -> [SampleRange] {
        var all: [SampleRange] = []
        for (chunk, start) in table.offsets.enumerated() {
            let held = table.runs.last { $0.firstChunk <= chunk + 1 }!.samplesPerChunk
            var offset = start
            for _ in 0..<held where all.count < table.sizes.count {
                let size = table.sizes[all.count]
                all.append(SampleRange(offset: offset, size: size))
                offset += UInt64(size)
            }
        }
        return Array(all.dropFirst(first).prefix(count))
    }

    @Test("the ranges are where each chunk's samples sit, one after another from the chunk's offset")
    func rangesFollowTheChunks() throws {
        let seed: UInt64 = 0x5A3B_0001
        var random = SplitMixRandom(seed: seed)
        for index in 0..<300 {
            let wide = Bool.random(using: &random)
            let table = Self.table(using: &random, offsetsBelow: wide ? 1 << 40 : 1 << 31)
            let first = Int.random(in: 0...(table.sizes.count + 2), using: &random)
            let count = Int.random(in: 1...40, using: &random)
            let stbl = Self.stsz(table.sizes) + Self.stsc(table) + (wide ? Self.co64(table.offsets) : Self.stco(table.offsets))

            #expect(try Self.ranges(stbl, from: first, count: count) == Self.naiveRanges(of: table, from: first, count: count),
                    "table \(index), seed \(seed)")
        }
    }

    @Test("a fixed sample size gives the ranges a table of that size for every sample gives")
    func fixedSizeIsATableOfOneSize() throws {
        let seed: UInt64 = 0x5A3B_0002
        var random = SplitMixRandom(seed: seed)
        for index in 0..<300 {
            let table = Self.table(using: &random, offsetsBelow: 1 << 31)
            let size = UInt32.random(in: 1...5000, using: &random)
            let first = Int.random(in: 0...(table.sizes.count + 2), using: &random)
            let count = Int.random(in: 1...40, using: &random)
            let chunks = Self.stsc(table) + Self.stco(table.offsets)

            #expect(
                try Self.ranges(Self.stsz(fixed: size, count: table.sizes.count) + chunks, from: first, count: count)
                    == Self.ranges(Self.stsz(Array(repeating: size, count: table.sizes.count)) + chunks, from: first, count: count),
                "table \(index), seed \(seed)")
        }
    }

    @Test("32-bit chunk offsets give the ranges the same offsets in 64 bits give")
    func stcoIsCo64() throws {
        let seed: UInt64 = 0x5A3B_0003
        var random = SplitMixRandom(seed: seed)
        for index in 0..<300 {
            let table = Self.table(using: &random, offsetsBelow: 1 << 32 - 1 << 20)
            let first = Int.random(in: 0...(table.sizes.count + 2), using: &random)
            let count = Int.random(in: 1...40, using: &random)
            let samples = Self.stsz(table.sizes) + Self.stsc(table)

            #expect(
                try Self.ranges(samples + Self.stco(table.offsets), from: first, count: count)
                    == Self.ranges(samples + Self.co64(table.offsets), from: first, count: count),
                "table \(index), seed \(seed)")
        }
    }
}

/// A seeded generator, so a property's inputs are the same on every run.
private struct SplitMixRandom: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var mixed = state
        mixed = (mixed ^ (mixed >> 30)) &* 0xBF58_476D_1CE4_E5B9
        mixed = (mixed ^ (mixed >> 27)) &* 0x94D0_49BB_1331_11EB
        return mixed ^ (mixed >> 31)
    }
}
