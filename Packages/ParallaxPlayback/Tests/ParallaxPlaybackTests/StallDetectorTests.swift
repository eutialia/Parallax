import Testing
import Foundation
@testable import ParallaxPlayback

@Suite("StallDetector")
struct StallDetectorTests {

    private let threshold = StallDetector.tripThreshold

    /// Feed `count` identical samples into a fresh detector; returns whether any tripped.
    private func feedFrozen(_ count: Int) -> Bool {
        var d = StallDetector()
        var tripped = false
        for _ in 0..<count {
            tripped = d.observe(timeMs: 100, readBytes: 5000) || tripped
        }
        return tripped
    }

    /// Loop bounds are driven off `tripThreshold` so a deliberate retune can't leave a
    /// silently-wrong "trips at 6" assertion behind.
    @Test("both axes frozen: trips on exactly the tripThreshold-th frozen comparison")
    func bothFrozenTripsAtThreshold() {
        var d = StallDetector()
        // The first sample only establishes the baseline — nothing to compare against.
        #expect(d.observe(timeMs: 100, readBytes: 5000) == false)
        for i in 1..<threshold {
            #expect(d.observe(timeMs: 100, readBytes: 5000) == false,
                    "frozen comparison \(i) must not trip yet")
        }
        #expect(d.observe(timeMs: 100, readBytes: 5000) == true)
    }

    /// 6 polls × the 500ms VLC progress poll = 3s frozen: long enough to ride out a
    /// keyframe hitch, far short of the 45s `StallWatchdog` failure.
    @Test("the baseline sample never counts toward the threshold")
    func baselineIsFree() {
        #expect(threshold == 6)
        #expect(feedFrozen(threshold + 1))          // baseline + threshold comparisons
        #expect(feedFrozen(threshold) == false)     // one comparison short
    }

    @Test("progress on either axis alone is not a stall", arguments: [
        ("bytes climbing, clock frozen (buffer refilling)", true),
        ("clock advancing, bytes frozen (playing out of buffer)", false),
    ])
    func oneAxisAdvancingIsNotStalled(label: String, bytesAdvance: Bool) {
        var d = StallDetector()
        _ = d.observe(timeMs: 100, readBytes: 5000)
        for i in 1...(threshold * 3) {
            let stalled = bytesAdvance
                ? d.observe(timeMs: 100, readBytes: 5000 + i * 1000)
                : d.observe(timeMs: 100 + Int32(i) * 500, readBytes: 5000)
            #expect(stalled == false, "\(label): tripped on poll \(i)")
        }
    }

    @Test("a single advance clears the frozen run")
    func advanceResetsCounter() {
        var d = StallDetector()
        _ = d.observe(timeMs: 100, readBytes: 5000)
        for _ in 0..<(threshold - 1) { _ = d.observe(timeMs: 100, readBytes: 5000) }
        #expect(d.observe(timeMs: 600, readBytes: 9000) == false)   // progress on both axes
        for _ in 0..<(threshold - 1) {
            #expect(d.observe(timeMs: 600, readBytes: 9000) == false)
        }
        #expect(d.observe(timeMs: 600, readBytes: 9000) == true)
    }

    @Test("stays tripped while the freeze persists")
    func staysTrippedWhileFrozen() {
        var d = StallDetector()
        for _ in 0...threshold { _ = d.observe(timeMs: 100, readBytes: 5000) }
        #expect(d.observe(timeMs: 100, readBytes: 5000) == true)
        #expect(d.observe(timeMs: 100, readBytes: 5000) == true)
    }

    /// Called on pause/seek/load, where the next sample must not be compared against a
    /// pre-seek baseline that would read as frozen.
    @Test("reset() drops the baseline and the counter")
    func resetClearsState() {
        var d = StallDetector()
        for _ in 0..<threshold { _ = d.observe(timeMs: 100, readBytes: 5000) }
        d.reset()
        #expect(d.observe(timeMs: 100, readBytes: 5000) == false)   // fresh baseline
        for _ in 0..<(threshold - 1) {
            #expect(d.observe(timeMs: 100, readBytes: 5000) == false)
        }
        #expect(d.observe(timeMs: 100, readBytes: 5000) == true)
    }
}
