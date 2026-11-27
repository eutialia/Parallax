import Testing
import ParallaxCoreTestSupport
@testable import ParallaxPlayback

/// `MediaClock` over generated clocks and source times, against a naive conversion written with
/// a quotient and a remainder.
@Suite("MediaClock — properties")
struct MediaClockProperties {
    private static let cases = 500
    private static let second: Int128 = 1_000_000_000

    /// `numerator / denominator` to the nearest, a half away from zero.
    private static func nearest(_ numerator: Int128, over denominator: Int128) -> Int64 {
        let (quotient, remainder) = numerator.quotientAndRemainder(dividingBy: denominator)
        guard 2 * remainder.magnitude >= denominator.magnitude else { return Int64(quotient) }
        return Int64(quotient + (numerator < 0 ? -1 : 1))
    }

    private static func plain(_ clock: MediaClock, at source: Int64) -> Int64 {
        nearest(Int128(source + clock.origin) * Int128(clock.timescale), over: second)
    }

    /// The tick of slot 0, where the anchor is.
    private static func base(_ clock: MediaClock, _ grid: MediaClock.Grid) -> Int64 {
        nearest(Int128(grid.anchor + clock.origin) * Int128(clock.timescale), over: second)
    }

    /// The source time of slot `slot`, to the nearest nanosecond.
    private static func time(ofSlot slot: Int64, _ clock: MediaClock, _ grid: MediaClock.Grid) -> Int64 {
        grid.anchor + nearest(Int128(slot) * Int128(grid.step) * second, over: Int128(clock.timescale))
    }

    /// Nanoseconds between neighboring slots, rounded down.
    private static func spacing(_ clock: MediaClock, _ grid: MediaClock.Grid) -> Int64 {
        Int64(Int128(grid.step) * second / Int128(clock.timescale))
    }

    /// A video clock at a broadcast or film rate, or an audio clock at a sample rate with a
    /// codec's frame length.
    private static func clock(
        _ random: inout SeededGenerator, tolerance: Tolerance, framesPerSample: Int64 = 1
    ) -> (MediaClock, MediaClock.Grid) {
        let (timescale, step): (Int64, Int64) = Bool.random(using: &random)
            ? (120_000, [5005, 5000, 4800, 4004, 4000, 2400, 2002, 2000].randomElement(using: &random)!)
            : ([8000, 44_100, 48_000, 96_000].randomElement(using: &random)!,
               [40, 500, 960, 1024, 1152, 1536, 2048].randomElement(using: &random)!)
        let anchor = Int64.random(in: -2_000_000_000...2_000_000_000, using: &random)
        let origin = Int64.random(in: 0...5_000_000_000, using: &random)
        let spacing = Int64(Int128(step) * second / Int128(timescale))
        let within: Int64 = switch tolerance {
        case .nearest: .max
        case .belowHalfASlot: Int64.random(in: 0...spacing / 2 - 2, using: &random)
        }
        let grid = MediaClock.Grid(anchor: anchor, step: step, tolerance: within, framesPerSample: framesPerSample)
        return (MediaClock(timescale: timescale, origin: origin, grid: grid), grid)
    }

    private enum Tolerance { case nearest, belowHalfASlot }

    /// A source time up to ten seconds either side of the anchor, where slots below zero are,
    /// or anywhere in a long file.
    private static func source(around grid: MediaClock.Grid, _ random: inout SeededGenerator) -> Int64 {
        Bool.random(using: &random)
            ? grid.anchor + Int64.random(in: -10_000_000_000...10_000_000_000, using: &random)
            : Int64.random(in: -5_000_000_000...20_000_000_000_000, using: &random)
    }

    @Test("without a grid a time is the source time plus the origin, in ticks to the nearest")
    func noGridIsPlainConversion() {
        let seed = UInt64(0x6E6F_6772_6964)
        var random = SeededGenerator(seed: seed)
        for _ in 0..<Self.cases {
            let clock = MediaClock(
                timescale: [1000, 8000, 44_100, 48_000, 90_000, 120_000].randomElement(using: &random)!,
                origin: Int64.random(in: 0...5_000_000_000, using: &random), grid: nil)
            let source = Int64.random(in: -10_000_000_000...20_000_000_000_000, using: &random)
            #expect(clock.ticks(at: source) == Self.plain(clock, at: source), "seed \(seed): \(clock) at \(source)")
            #expect(clock.seconds(at: source) == Double(clock.ticks(at: source)) / Double(clock.timescale), "seed \(seed)")
        }
    }

    /// A frame stored at its rate's time rounded to the container's tick is within the
    /// tolerance of its slot.
    @Test("a frame within the tolerance of a slot lands exactly on it, and a slot's own time comes back as that slot")
    func frameNearItsSlotTakesIt() {
        let seed = UInt64(0x736C_6F74_7300)
        var random = SeededGenerator(seed: seed)
        for _ in 0..<Self.cases {
            let (clock, grid) = Self.clock(&random, tolerance: .belowHalfASlot)
            let slot = Int64.random(in: -1000...200_000, using: &random)
            let slotTime = Self.time(ofSlot: slot, clock, grid)
            // Two cases in three sit on the tolerance itself, one either side.
            let offset = [-grid.tolerance, grid.tolerance, Int64.random(in: -grid.tolerance...grid.tolerance, using: &random)]
                .randomElement(using: &random)!
            let source = slotTime + offset
            let expected = Self.base(clock, grid) + slot * grid.step
            #expect(clock.ticks(at: source) == expected, "seed \(seed): \(clock) at \(source), slot \(slot)")
            #expect(clock.ticks(at: slotTime) == expected, "seed \(seed): \(clock) at \(slotTime), slot \(slot)")
        }
    }

    @Test("a frame more than the tolerance from every slot keeps its own time")
    func offGridFrameKeepsItsTime() {
        let seed = UInt64(0x6F66_6667_7269)
        var random = SeededGenerator(seed: seed)
        for _ in 0..<Self.cases {
            let (clock, grid) = Self.clock(&random, tolerance: .belowHalfASlot)
            let slot = Int64.random(in: -1000...200_000, using: &random)
            let farthest = Self.spacing(clock, grid) / 2 - 1
            // A case in three sits a nanosecond past the tolerance, and one at half a slot.
            let distance = [grid.tolerance + 1, Int64.random(in: grid.tolerance + 1...farthest, using: &random), farthest]
                .randomElement(using: &random)!
            let source = Self.time(ofSlot: slot, clock, grid) + (Bool.random(using: &random) ? distance : -distance)
            #expect(clock.ticks(at: source) == Self.plain(clock, at: source), "seed \(seed): \(clock) at \(source)")
        }
    }

    @Test("an audio frame takes the nearest slot however far the stored time drifted, below zero too")
    func audioAlwaysTakesTheNearestSlot() throws {
        let seed = UInt64(0x6E65_6172_6573)
        var random = SeededGenerator(seed: seed)
        for _ in 0..<Self.cases {
            let (clock, grid) = Self.clock(&random, tolerance: .nearest)
            let source = Self.source(around: grid, &random)
            let offset = clock.ticks(at: source) - Self.base(clock, grid)
            #expect(offset % grid.step == 0, "seed \(seed): \(clock) at \(source)")
            let slot = offset / grid.step
            let distance = { (slot: Int64) in abs(source - Self.time(ofSlot: slot, clock, grid)) }
            #expect(distance(slot) <= distance(slot - 1) && distance(slot) <= distance(slot + 1), "seed \(seed): \(clock) at \(source)")
        }
    }

    @Test("a joined MP4 sample starts on a slot the join counts from the anchor, the frame's own or up to the join's length before it, and its start is its own")
    func sampleStartIsTheJoinsFirstFrame() {
        let seed = UInt64(0x6A6F_696E_6564)
        var random = SeededGenerator(seed: seed)
        for _ in 0..<Self.cases {
            let joined = Int64.random(in: 1...4, using: &random)
            let (clock, grid) = Self.clock(&random, tolerance: .nearest, framesPerSample: joined)
            let source = Self.source(around: grid, &random)
            let start = clock.sampleStart(at: source)
            let slot = { (time: Int64) in (clock.ticks(at: time) - Self.base(clock, grid)) / grid.step }

            if joined == 1 { #expect(start == source, "seed \(seed)") }
            #expect(slot(start) % joined == 0, "seed \(seed): \(clock) at \(source)")
            #expect((0..<joined).contains(slot(source) - slot(start)), "seed \(seed): \(clock) at \(source)")
            #expect(clock.sampleStart(at: start) == start, "seed \(seed): \(clock) at \(source)")
        }
    }
}
