import Testing
@testable import ParallaxPlayback

@Suite("MediaClock")
struct MediaClockTests {
    private static let film = MediaClock(
        timescale: 120_000, origin: 105_000_000,
        grid: .init(anchor: 0, step: 5000, tolerance: 1_000_000))

    @Test("a frame stored at its rate's time rounded to a millisecond lands exactly on its slot")
    func roundedFrameTimeTakesItsSlot() {
        // Frame 1 of 24 per second is at 41.67 ms, stored as 42. Slot 0 is at 105 ms: 12,600 ticks.
        #expect(Self.film.ticks(at: 42_000_000) == 17_600)
        #expect(Self.film.ticks(at: 11_958_000_000) == 12_600 + 287 * 5000)
    }

    @Test("a frame more than the tolerance from every slot keeps its own time")
    func offGridFrameKeepsItsTime() {
        #expect(Self.film.ticks(at: 60_000_000) == 19_800)
    }

    @Test("without a grid a time is the source time plus the origin")
    func noGridIsPlainConversion() {
        let clock = MediaClock(timescale: 120_000, origin: 105_000_000, grid: nil)
        #expect(clock.ticks(at: 42_000_000) == 17_640)
    }

    @Test("an audio frame takes the nearest slot however far the stored time drifted, below zero too")
    func audioAlwaysTakesTheNearestSlot() {
        let clock = MediaClock(
            timescale: 48_000, origin: 105_000_000,
            grid: .init(anchor: -21_000_000, step: 1024, tolerance: .max))
        // Frame 7 of 1024-sample frames is 149.33 ms after the first. mkvmerge's lacing leaves
        // it stored 148 ms after.
        #expect(clock.ticks(at: 127_000_000) == 4032 + 7 * 1024)
        #expect(clock.ticks(at: -42_000_000) == 4032 - 1024)
    }
}
