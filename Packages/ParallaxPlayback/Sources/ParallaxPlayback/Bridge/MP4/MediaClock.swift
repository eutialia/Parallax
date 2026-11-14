/// Where a time in the source file falls on one rendition's media timeline.
///
/// The answer depends only on the time asked about, never on what was asked before, so a
/// segment built on its own carries the same times as one built in sequence.
struct MediaClock: Sendable, Equatable {
    /// Ticks per second.
    let timescale: Int64
    /// Nanoseconds added to every source time. One value for all renditions of a file, large
    /// enough that no rendition starts below zero.
    let origin: Int64
    let grid: Grid?

    /// The exact spacing of a stream whose samples are evenly spaced: video at a standard frame
    /// rate, audio with a fixed frame length. The container stores times rounded to its own
    /// tick (a millisecond in most Matroska files), and the grid undoes that rounding.
    struct Grid: Sendable, Equatable {
        /// Nanoseconds. The source time of one sample known to sit on the grid.
        let anchor: Int64
        /// Ticks between neighboring samples.
        let step: Int64
        /// Nanoseconds. A time further than this from its slot keeps its own value, so a
        /// variable-rate stretch of video is not forced onto the grid. Audio frames are
        /// continuous by nature and always take the nearest slot (`.max`): a muxer that packs
        /// several frames into one block stores a time for the first only, and the rest drift
        /// from the grid by a rounding error each.
        let tolerance: Int64
        /// Frames the muxer joins into one MP4 sample: two or more for E-AC-3 frames of fewer than
        /// six blocks, one otherwise. Counted from the anchor.
        let framesPerSample: Int64

        init(anchor: Int64, step: Int64, tolerance: Int64, framesPerSample: Int64 = 1) {
            self.anchor = anchor
            self.step = step
            self.tolerance = tolerance
            self.framesPerSample = framesPerSample
        }
    }

    func ticks(at source: Int64) -> Int64 {
        let plain = Self.rounded(Int128(source + origin) * Int128(timescale), over: Self.second)
        guard let grid else { return plain }
        let slot = slot(at: source, on: grid)
        guard abs(source - time(ofSlot: slot, on: grid)) <= grid.tolerance else { return plain }
        return Self.rounded(Int128(grid.anchor + origin) * Int128(timescale), over: Self.second) + slot * grid.step
    }

    /// The source time of the first frame of the MP4 sample the frame at `source` goes into:
    /// `source` itself, unless the grid joins frames.
    func sampleStart(at source: Int64) -> Int64 {
        guard let grid, grid.framesPerSample > 1 else { return source }
        let slot = slot(at: source, on: grid)
        let count = grid.framesPerSample
        return time(ofSlot: slot - (slot % count + count) % count, on: grid)
    }

    func seconds(at source: Int64) -> Double {
        Double(ticks(at: source)) / Double(timescale)
    }

    private static let second: Int128 = 1_000_000_000

    private func slot(at source: Int64, on grid: Grid) -> Int64 {
        Self.rounded(Int128(source - grid.anchor) * Int128(timescale), over: Int128(grid.step) * Self.second)
    }

    private func time(ofSlot slot: Int64, on grid: Grid) -> Int64 {
        grid.anchor + Self.rounded(Int128(slot) * Int128(grid.step) * Self.second, over: Int128(timescale))
    }

    private static func rounded(_ numerator: Int128, over denominator: Int128) -> Int64 {
        let doubled = 2 * numerator + (numerator < 0 ? -denominator : denominator)
        return Int64(doubled / (2 * denominator))
    }
}
