import Foundation
import Testing
@testable import ParallaxCore

@Suite("Duration.compactRuntimeLabel")
struct DurationRuntimeLabelTests {
    /// The literals here ARE the spec: this is a seconds → display-string formatter, so the
    /// output strings are the thing under test, not a re-derivation of a production constant.
    @Test("renders whole-minute runtimes, flooring the leftover seconds", arguments: [
        (83 * 60, "1h 23m"),          // hours + minutes
        (2 * 3600, "2h"),             // whole hours drop the minutes component
        (45 * 60, "45m"),             // sub-hour is minutes only
        (60 * 60 + 60, "1h 1m"),      // a single leftover minute still renders
        (30, "<1m"),                  // sub-minute collapses
        (59, "<1m"),                  // …right up to the boundary
        (83 * 60 + 59, "1h 23m"),     // leftover seconds floor, never spill into 24m
        (0, ""),                      // zero renders nothing, not "0m"
        (-120, ""),                   // and neither does a negative
    ])
    func compactLabel(seconds: Int, expected: String) {
        #expect(Duration.seconds(seconds).compactRuntimeLabel == expected)
    }
}
