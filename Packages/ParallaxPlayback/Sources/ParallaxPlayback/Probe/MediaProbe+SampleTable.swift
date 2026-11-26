import Foundation

/// Where a track's samples sit in the file, from its sample table: `stsz` for their sizes,
/// `stsc` for how many go in each chunk, and `stco` or `co64` for where each chunk starts.
extension MediaProbe {
    struct SampleRange: Equatable {
        let offset: UInt64
        let size: UInt32
    }

    /// The ranges of up to `count` samples from sample `first`, in decode order, as the
    /// `stbl` content in `data[stbl]` places them. Empty when the table holds no sample from
    /// `first`, nil when one of the tables is missing or cut short.
    static func sampleRanges(from first: Int, count: Int, in data: Data, stbl: Range<Int>) -> [SampleRange]? {
        guard let stsz = firstChildBox(data, type: "stsz", in: stbl), let sizes = sampleSizes(data, box: stsz),
              let stsc = firstChildBox(data, type: "stsc", in: stbl), let chunks = chunkRuns(data, box: stsc),
              let offsets = chunkOffsets(data, stbl: stbl)
        else { return nil }
        return sampleRanges(from: first, count: count, sizes: sizes, chunks: chunks, chunkOffsets: offsets)
    }

    /// One fixed size for every sample, or a size per sample. A fixed size stays unexpanded: a
    /// hostile `stsz` can declare millions of samples in 20 bytes.
    private enum SampleSizes {
        case fixed(size: UInt32, count: Int)
        case table([UInt32])

        var count: Int {
            switch self {
            case .fixed(_, let count): count
            case .table(let sizes): sizes.count
            }
        }

        subscript(_ index: Int) -> UInt32 {
            switch self {
            case .fixed(let size, _): size
            case .table(let sizes): sizes[index]
            }
        }
    }

    /// An `stsc` entry: from chunk `firstChunk`, counted from 1, each chunk holds
    /// `samplesPerChunk` samples.
    private struct ChunkRun {
        let firstChunk: UInt32
        let samplesPerChunk: UInt32
    }

    private static func sampleSizes(_ data: Data, box: BoxHeader) -> SampleSizes? {
        let start = box.contentStart + 4
        guard start + 8 <= box.boxEnd, start + 8 <= data.count else { return nil }
        let sampleSize = readUInt32BE(data, at: start)
        let sampleCount = Int(readUInt32BE(data, at: start + 4))
        // A fixed size has no table bytes to bound a garbage count; 74 hours at 30 fps fits.
        guard sampleCount <= 8_000_000 else { return nil }
        if sampleSize != 0 { return .fixed(size: sampleSize, count: sampleCount) }

        var offset = start + 8
        var sizes: [UInt32] = []
        sizes.reserveCapacity(min(sampleCount, max(0, box.boxEnd - offset) / 4))
        for _ in 0..<sampleCount {
            guard offset + 4 <= box.boxEnd, offset + 4 <= data.count else { return nil }
            sizes.append(readUInt32BE(data, at: offset))
            offset += 4
        }
        return .table(sizes)
    }

    private static func chunkRuns(_ data: Data, box: BoxHeader) -> [ChunkRun]? {
        let start = box.contentStart + 4
        guard start + 4 <= box.boxEnd, start + 4 <= data.count else { return nil }
        let count = Int(readUInt32BE(data, at: start))
        var offset = start + 4
        var runs: [ChunkRun] = []
        runs.reserveCapacity(min(count, max(0, box.boxEnd - offset) / 12))
        for _ in 0..<count {
            guard offset + 12 <= box.boxEnd, offset + 12 <= data.count else { return nil }
            runs.append(ChunkRun(firstChunk: readUInt32BE(data, at: offset), samplesPerChunk: readUInt32BE(data, at: offset + 4)))
            offset += 12
        }
        guard !runs.isEmpty else { return nil }
        return runs
    }

    /// `stco`'s 32-bit offsets, or `co64`'s 64-bit ones where there is no `stco`.
    private static func chunkOffsets(_ data: Data, stbl: Range<Int>) -> [UInt64]? {
        let table = firstChildBox(data, type: "stco", in: stbl).map { (box: $0, width: 4) }
            ?? firstChildBox(data, type: "co64", in: stbl).map { (box: $0, width: 8) }
        guard let table else { return nil }
        let (box, width) = table
        let start = box.contentStart + 4
        guard start + 4 <= box.boxEnd, start + 4 <= data.count else { return nil }
        let count = Int(readUInt32BE(data, at: start))
        var offset = start + 4
        var offsets: [UInt64] = []
        offsets.reserveCapacity(min(count, max(0, box.boxEnd - offset) / width))
        for _ in 0..<count {
            guard offset + width <= box.boxEnd, offset + width <= data.count else { return nil }
            offsets.append(width == 4 ? UInt64(readUInt32BE(data, at: offset)) : readUInt64BE(data, at: offset))
            offset += width
        }
        return offsets
    }

    /// Walks the chunks in order, summing the sizes of the samples before each within its chunk.
    private static func sampleRanges(
        from first: Int, count: Int, sizes: SampleSizes, chunks: [ChunkRun], chunkOffsets: [UInt64]
    ) -> [SampleRange] {
        guard first >= 0, first < sizes.count, count > 0, !chunkOffsets.isEmpty else { return [] }
        let wanted = min(count, sizes.count - first)

        var results: [SampleRange] = []
        results.reserveCapacity(wanted)
        var sampleIndex = 0
        var run = 0
        for chunkNumber in 1...chunkOffsets.count {
            while run + 1 < chunks.count, UInt32(chunkNumber) >= chunks[run + 1].firstChunk {
                run += 1
            }
            var runningOffset = chunkOffsets[chunkNumber - 1]
            for _ in 0..<Int(chunks[run].samplesPerChunk) {
                guard sampleIndex < sizes.count else { break }
                let size = sizes[sampleIndex]
                if sampleIndex >= first { results.append(SampleRange(offset: runningOffset, size: size)) }
                if results.count >= wanted { return results }
                let (next, overflow) = runningOffset.addingReportingOverflow(UInt64(size))
                guard !overflow else { return results }  // a garbage chunk offset table
                runningOffset = next
                sampleIndex += 1
            }
        }
        return results
    }
}
