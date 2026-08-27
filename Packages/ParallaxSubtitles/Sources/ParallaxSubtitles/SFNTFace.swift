import Foundation

/// Reads the parts of an sfnt file that decide how libass NAMES and SIZES a
/// face, straight from the file's own tables.
///
/// Collection-aware on purpose: the bundled pan-CJK builds are OTCs whose
/// faces differ only by name table (`Noto Sans CJK JP` / ` SC` / ` TC` / ` KR`),
/// and libass indexes every one of them separately — so "the file's metrics"
/// is not a thing, "this family's metrics" is.
enum SFNTFace {

    /// The vertical-metric fields libass consumes. It sizes VSFilter-style from
    /// OS/2 usWinAscent+usWinDescent, so this is what turns a requested point
    /// size into rendered pixels.
    struct Metrics: Equatable, Sendable {
        var unitsPerEm: UInt16
        var winAscent: UInt16
        var winDescent: UInt16
    }

    struct Face: Equatable, Sendable {
        /// nameID 1 — the only name libass matches `\fn` against.
        let familyName: String
        let metrics: Metrics
        /// The scalars this face can draw, read from its `cmap`.
        let coverage: Coverage
    }

    /// The scalars a face draws, as coalesced ranges.
    ///
    /// Ranges rather than a `Set`: a pan-CJK face maps ~45,000 code points and
    /// the bundle carries fifteen of them, so a set of every covered scalar
    /// would cost tens of megabytes to answer a question that is almost entirely
    /// contiguous. Sorted and disjoint, so membership is a bisection.
    struct Coverage: Equatable, Sendable {
        let ranges: [ClosedRange<UInt32>]

        static let empty = Coverage(ranges: [])

        func contains(_ value: UInt32) -> Bool {
            var low = 0
            var high = ranges.count - 1
            while low <= high {
                let middle = (low + high) / 2
                if value < ranges[middle].lowerBound {
                    high = middle - 1
                } else if value > ranges[middle].upperBound {
                    low = middle + 1
                } else {
                    return true
                }
            }
            return false
        }
    }

    /// Every face of `url`, in file order. Empty when the file is not sfnt-based
    /// or its tables don't parse.
    static func faces(of url: URL) -> [Face] {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return [] }
        let bytes = Bytes(data)
        guard let tag = bytes.u32(0) else { return [] }

        let faceOffsets: [Int]
        if tag == 0x7474_6366 {  // 'ttcf'
            guard let count = bytes.u32(8), count > 0, count < 256 else { return [] }
            faceOffsets = (0..<Int(count)).compactMap { bytes.u32(12 + 4 * $0).map(Int.init) }
        } else if tag == 0x0001_0000 || tag == 0x4F54_544F || tag == 0x7472_7565 {
            faceOffsets = [0]
        } else {
            return []
        }

        return faceOffsets.compactMap { offset in
            guard let tables = tableDirectory(bytes, at: offset),
                  let familyName = familyName(bytes, tables),
                  let metrics = metrics(bytes, tables)
            else { return nil }
            return Face(
                familyName: familyName,
                metrics: metrics,
                coverage: coverage(bytes, tables)
            )
        }
    }

    // MARK: - Tables

    private static func tableDirectory(_ bytes: Bytes, at offset: Int) -> [UInt32: Int]? {
        guard let numTables = bytes.u16(offset + 4), numTables > 0, numTables < 512 else { return nil }
        var tables: [UInt32: Int] = [:]
        for index in 0..<Int(numTables) {
            let entry = offset + 12 + index * 16
            guard let tag = bytes.u32(entry), let start = bytes.u32(entry + 8) else { return nil }
            tables[tag] = Int(start)
        }
        return tables
    }

    /// nameID 1, preferring the Windows/Unicode/en-US record every modern font
    /// carries and falling back to the Macintosh/Roman one older files use.
    private static func familyName(_ bytes: Bytes, _ tables: [UInt32: Int]) -> String? {
        guard let name = tables[0x6E61_6D65],  // 'name'
              let count = bytes.u16(name + 2),
              let storage = bytes.u16(name + 4)
        else { return nil }

        var windows: String?
        var macintosh: String?
        for index in 0..<Int(count) {
            let record = name + 6 + index * 12
            guard let platform = bytes.u16(record), let encoding = bytes.u16(record + 2),
                  let language = bytes.u16(record + 4), let nameID = bytes.u16(record + 6),
                  let length = bytes.u16(record + 8), let offset = bytes.u16(record + 10),
                  nameID == 1,
                  let raw = bytes.slice(name + Int(storage) + Int(offset), Int(length))
            else { continue }
            if platform == 3, encoding == 1, language == 0x409 {
                windows = String(data: raw, encoding: .utf16BigEndian)
            } else if platform == 1, encoding == 0, language == 0 {
                macintosh = String(data: raw, encoding: .macOSRoman)
            }
        }
        return windows ?? macintosh
    }

    private static func metrics(_ bytes: Bytes, _ tables: [UInt32: Int]) -> Metrics? {
        guard let head = tables[0x6865_6164],  // 'head'
              let os2 = tables[0x4F53_2F32],   // 'OS/2'
              let unitsPerEm = bytes.u16(head + 18),
              let winAscent = bytes.u16(os2 + 74),
              let winDescent = bytes.u16(os2 + 76)
        else { return nil }

        return Metrics(unitsPerEm: unitsPerEm, winAscent: winAscent, winDescent: winDescent)
    }

    // MARK: - cmap

    /// The face's `cmap`, read as ranges of drawable scalars.
    ///
    /// Preferring a full-repertoire subtable over the BMP-only 3/1 matters: the
    /// pan-CJK collections address plane 2, and format 4 cannot reach it. A code
    /// point inside a segment still has to map to a NON-ZERO glyph — `.notdef`
    /// is what tofu is — so format 4's `idDelta`/`idRangeOffset` are followed
    /// rather than assumed.
    private static func coverage(_ bytes: Bytes, _ tables: [UInt32: Int]) -> Coverage {
        guard let cmap = tables[0x636D_6170],  // 'cmap'
              let subtableCount = bytes.u16(cmap + 2)
        else { return .empty }

        var best: (rank: Int, offset: Int)?
        for index in 0..<Int(subtableCount) {
            let record = cmap + 4 + index * 8
            guard let platform = bytes.u16(record), let encoding = bytes.u16(record + 2),
                  let offset = bytes.u32(record + 4)
            else { continue }
            let rank: Int
            switch (platform, encoding) {
            case (3, 10), (0, 4), (0, 6): rank = 3
            case (3, 1), (0, 3): rank = 2
            case (0, _): rank = 1
            default: continue
            }
            if best == nil || rank > best!.rank { best = (rank, cmap + Int(offset)) }
        }
        guard let best else { return .empty }

        switch bytes.u16(best.offset) {
        case 4: return Coverage(ranges: format4(bytes, at: best.offset))
        case 12: return Coverage(ranges: format12(bytes, at: best.offset))
        default: return .empty
        }
    }

    private static func format4(_ bytes: Bytes, at offset: Int) -> [ClosedRange<UInt32>] {
        guard let segCountX2 = bytes.u16(offset + 6) else { return [] }
        let ends = offset + 14
        let starts = ends + Int(segCountX2) + 2
        let deltas = starts + Int(segCountX2)
        let rangeOffsets = deltas + Int(segCountX2)

        var builder = RangeBuilder()
        for segment in stride(from: 0, to: Int(segCountX2), by: 2) {
            guard let end = bytes.u16(ends + segment), let start = bytes.u16(starts + segment),
                  let delta = bytes.u16(deltas + segment),
                  let rangeOffset = bytes.u16(rangeOffsets + segment),
                  start <= end, !(start == 0xFFFF && end == 0xFFFF)
            else { continue }
            for code in start...end {
                let glyph: UInt16
                if rangeOffset == 0 {
                    glyph = code &+ delta
                } else {
                    let address = rangeOffsets + segment + Int(rangeOffset)
                        + 2 * Int(code - start)
                    guard let raw = bytes.u16(address), raw != 0 else { continue }
                    glyph = raw &+ delta
                }
                if glyph != 0 { builder.add(UInt32(code)) }
            }
        }
        return builder.ranges
    }

    private static func format12(_ bytes: Bytes, at offset: Int) -> [ClosedRange<UInt32>] {
        guard let groups = bytes.u32(offset + 12), groups < 200_000 else { return [] }
        var builder = RangeBuilder()
        for index in 0..<Int(groups) {
            let group = offset + 16 + index * 12
            guard let start = bytes.u32(group), let end = bytes.u32(group + 4),
                  let startGlyph = bytes.u32(group + 8),
                  start <= end, end - start < 0x20000, startGlyph != 0
            else { continue }
            builder.add(start...end)
        }
        return builder.ranges
    }

    /// Coalesces covered code points into as few ranges as possible; a cmap is
    /// read in ascending order, so neighbours arrive adjacent.
    private struct RangeBuilder {
        private(set) var ranges: [ClosedRange<UInt32>] = []

        mutating func add(_ value: UInt32) { add(value...value) }

        mutating func add(_ range: ClosedRange<UInt32>) {
            if let last = ranges.last, range.lowerBound <= last.upperBound &+ 1,
               range.lowerBound >= last.lowerBound {
                ranges[ranges.count - 1] = last.lowerBound...max(last.upperBound, range.upperBound)
            } else {
                ranges.append(range)
            }
        }
    }

    // MARK: - Bounds-checked big-endian reads

    /// Every offset in an sfnt comes from the file itself, so a truncated or
    /// hostile font must read as "absent", never as a trap.
    private struct Bytes {
        private let data: Data

        init(_ data: Data) { self.data = data }

        func u8(_ offset: Int) -> UInt8? {
            data.indices.contains(offset) ? data[offset] : nil
        }

        func u16(_ offset: Int) -> UInt16? {
            guard let high = u8(offset), let low = u8(offset + 1) else { return nil }
            return UInt16(high) << 8 | UInt16(low)
        }

        func u32(_ offset: Int) -> UInt32? {
            guard let high = u16(offset), let low = u16(offset + 2) else { return nil }
            return UInt32(high) << 16 | UInt32(low)
        }

        func slice(_ offset: Int, _ count: Int) -> Data? {
            guard count >= 0, offset >= 0, offset + count <= data.count else { return nil }
            return data.subdata(in: offset..<(offset + count))
        }
    }
}
