import Testing
import Foundation
@testable import ParallaxPlayback

@Suite("StallDetector")
struct StallDetectorTests {

    /// Feed `count` identical (frozen) samples after an initial baseline, returning whether any
    /// observe tripped and how many samples it took.
    private func feedFrozen(_ count: Int, timeMs: Int32 = 100, readBytes: Int = 5000) -> Bool {
        var d = StallDetector()
        var tripped = false
        for _ in 0..<count {
            tripped = d.observe(timeMs: timeMs, readBytes: readBytes) || tripped
        }
        return tripped
    }

    @Test("both frozen: trips exactly at the 6th frozen poll, not before")
    func bothFrozenTripsAtThreshold() {
        var d = StallDetector()
        // Sample 1 sets the baseline (no comparison) → false.
        #expect(d.observe(timeMs: 100, readBytes: 5000) == false)
        // Frozen comparisons 1…5 accumulate but don't trip.
        for _ in 0..<5 {
            #expect(d.observe(timeMs: 100, readBytes: 5000) == false)
        }
        // The 6th frozen comparison reaches tripThreshold.
        #expect(d.observe(timeMs: 100, readBytes: 5000) == true)
    }

    @Test("tripThreshold is 6 (3s at the 500ms poll)")
    func thresholdIsSix() {
        #expect(StallDetector.tripThreshold == 6)
        // 7 identical samples = baseline + 6 frozen comparisons → trips.
        #expect(feedFrozen(7))
        // 6 identical samples = baseline + 5 frozen comparisons → not yet.
        #expect(feedFrozen(6) == false)
    }

    @Test("bytes advancing while time is frozen: NOT a stall (network alive, buffer refilling)")
    func bytesAdvancingIsNotStalled() {
        var d = StallDetector()
        _ = d.observe(timeMs: 100, readBytes: 5000)   // baseline
        // Time pinned (decoder starving) but the demux counter climbs every poll → the network is
        // still feeding the buffer; let it recover, never trip.
        for i in 1...20 {
            #expect(d.observe(timeMs: 100, readBytes: 5000 + i * 1000) == false)
        }
    }

    @Test("time advancing while bytes are frozen: NOT a stall (playing out of buffer / EOF tail)")
    func timeAdvancingIsNotStalled() {
        var d = StallDetector()
        _ = d.observe(timeMs: 100, readBytes: 5000)   // baseline
        // The clock advances (frames rendering from the buffer) while the demux counter is static —
        // draining an already-read tail. Never a stall.
        for i in 1...20 {
            #expect(d.observe(timeMs: 100 + Int32(i) * 500, readBytes: 5000) == false)
        }
    }

    @Test("a single advance resets the frozen run")
    func advanceResetsCounter() {
        var d = StallDetector()
        _ = d.observe(timeMs: 100, readBytes: 5000)   // baseline
        for _ in 0..<5 { _ = d.observe(timeMs: 100, readBytes: 5000) }   // 5 frozen, one short
        // Progress on either axis clears the run.
        #expect(d.observe(timeMs: 600, readBytes: 9000) == false)
        // Must now take a fresh full run of 6 to trip.
        for _ in 0..<5 { #expect(d.observe(timeMs: 600, readBytes: 9000) == false) }
        #expect(d.observe(timeMs: 600, readBytes: 9000) == true)
    }

    @Test("stays tripped while the freeze persists")
    func staysTrippedWhileFrozen() {
        var d = StallDetector()
        for _ in 0..<7 { _ = d.observe(timeMs: 100, readBytes: 5000) }   // now tripped
        #expect(d.observe(timeMs: 100, readBytes: 5000) == true)
        #expect(d.observe(timeMs: 100, readBytes: 5000) == true)
    }

    @Test("reset() drops the baseline and counter so a fresh window starts clean")
    func resetClearsState() {
        var d = StallDetector()
        for _ in 0..<5 { _ = d.observe(timeMs: 100, readBytes: 5000) }   // 4 frozen accumulated
        d.reset()
        // Post-reset the next sample is a fresh baseline; it takes a full run of 6 again.
        #expect(d.observe(timeMs: 100, readBytes: 5000) == false)   // new baseline
        for _ in 0..<5 { #expect(d.observe(timeMs: 100, readBytes: 5000) == false) }
        #expect(d.observe(timeMs: 100, readBytes: 5000) == true)
    }
}
